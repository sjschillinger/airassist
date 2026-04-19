import Foundation
import IOKit.ps
import os

/// When enabled, applies different `ThresholdPreset`s depending on
/// whether the Mac is running on battery or plugged in (#59).
///
/// Fanless Airs have two very different personalities: on AC they can
/// sustain load without much user-perceptible heat (no fans, but also
/// no lap to burn); on battery, heat and power draw are both the user's
/// problem. Shipping two threshold profiles and swapping between them
/// on power-source change is the smallest correct product feature for
/// this.
///
/// Scope kept deliberately narrow:
///   • Opt-in via `enabled`. Off by default — the governor preset and
///     thresholds are a user-tuned thing; we don't silently rewrite
///     them.
///   • Only toggles the `ThresholdSettings` that power the menu-bar
///     color / alerting. Doesn't swap Governor presets — those include
///     behavior (caps) rather than purely display thresholds, and
///     silent behavior changes surprise users more than silent display
///     changes.
///
/// Future extension (not shipped in v1.0): also swap `GovernorPreset`
/// per power source. That's "autonomous behavior change" and deserves
/// a separate explicit preference + confirmation.
@MainActor
final class BatteryAwareMode {
    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "BatteryAware")

    // MARK: - Persistence keys

    static let enabledKey        = "batteryAware.enabled"
    static let onBatteryPresetKey = "batteryAware.onBatteryPreset"
    static let onPoweredPresetKey = "batteryAware.onPoweredPreset"

    // MARK: - Configuration

    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { apply(force: true) } else { stop() }
        }
    }

    /// Preset applied while on battery. Default: aggressive.
    var onBatteryPreset: ThresholdPreset {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.onBatteryPresetKey),
                  let p = ThresholdPreset(rawValue: raw) else { return .aggressive }
            return p
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.onBatteryPresetKey)
            apply(force: true)
        }
    }

    /// Preset applied while plugged in. Default: balanced.
    var onPoweredPreset: ThresholdPreset {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.onPoweredPresetKey),
                  let p = ThresholdPreset(rawValue: raw) else { return .balanced }
            return p
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.onPoweredPresetKey)
            apply(force: true)
        }
    }

    // MARK: - Wiring

    /// Called on every applied transition. Owner supplies this so the
    /// service stays ignorant of `ThermalStore` concrete shape.
    var onApplyThresholds: ((ThresholdSettings) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var lastAppliedOnBattery: Bool?

    func start() {
        guard isEnabled else { return }
        installPowerSourceObserver()
        apply(force: true)
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = nil
        }
        lastAppliedOnBattery = nil
    }

    // MARK: - Internals

    /// Current snapshot of the power source. `true` = drawing from battery.
    private func isOnBatteryPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false // conservatively assume AC if we can't tell
        }
        let source = IOPSGetProvidingPowerSourceType(blob).takeUnretainedValue() as String
        // `kIOPMBatteryPowerKey` on battery, `kIOPMACPowerKey` on AC.
        return source == kIOPMBatteryPowerKey
    }

    /// Install a CFRunLoop source that fires whenever macOS reports a
    /// power-source change. Uses IOKit rather than NSWorkspace (which
    /// doesn't expose this transition directly).
    private func installPowerSourceObserver() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<BatteryAwareMode>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.apply(force: false) }
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        runLoopSource = src
    }

    /// Re-check the power source and, if it differs from the last applied
    /// state (or force is true), push the matching ThresholdSettings via
    /// the callback.
    private func apply(force: Bool) {
        guard isEnabled else { return }
        let onBattery = isOnBatteryPower()
        if !force, lastAppliedOnBattery == onBattery { return }
        let preset = onBattery ? onBatteryPreset : onPoweredPreset
        logger.info("power source → \(onBattery ? "battery" : "AC"); applying \(preset.rawValue)")
        onApplyThresholds?(preset.settings)
        lastAppliedOnBattery = onBattery
    }
}
