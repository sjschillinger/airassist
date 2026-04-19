import AppKit
import Carbon.HIToolbox
import os

/// Registers a global hotkey that toggles AirAssist's pause state.
///
/// ### Why Carbon, not NSEvent.addGlobalMonitorForEvents?
///
/// `NSEvent`'s global monitor requires Accessibility permission (System
/// Settings → Privacy & Security → Accessibility). That's a heavy prompt
/// for a single hotkey and the kind of thing that tanks install
/// completion — users see the scary dialog and close the app.
///
/// `RegisterEventHotKey` (Carbon HIToolbox) has been the supported way
/// to register process-global hotkeys since OS X 10.0 and does NOT
/// require Accessibility. Apple has kept it working through every macOS
/// release including the sandboxed-everything era. Downside: no Swift-
/// native wrapper, so we do the EventHandlerUPP dance ourselves.
///
/// See `docs/engineering-references.md` future entry "Global hotkey APIs"
/// for the trade-off matrix between NSEvent / Carbon / EventTap.
///
/// ### Default binding
///
/// ⌘⌥P ("Pause"). Toggles. Single binding shipped in v1.0; swap for a
/// user-configurable field later if demand emerges. Stored in
/// UserDefaults as boolean `globalHotkey.enabled` (default true) so the
/// user can disable it entirely if it collides with another app.
@MainActor
final class GlobalHotkeyService {
    static let shared = GlobalHotkeyService()

    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "GlobalHotkey")

    /// UserDefaults key for the on/off toggle.
    static let enabledDefaultsKey = "globalHotkey.enabled"

    /// Hotkey identifier signature — arbitrary 4-char code per Carbon convention.
    private let hotKeySignature: OSType = 0x41414141 // 'AAAA'
    private let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Set from owner (AppDelegate wires it to `store.isPauseActive` toggle).
    var onTrigger: (() -> Void)?

    // MARK: - Enable / disable

    var isEnabled: Bool {
        get {
            if let v = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool {
                return v
            }
            return true // default on
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            if newValue { install() } else { uninstall() }
        }
    }

    func start() {
        if isEnabled { install() }
    }

    func stop() {
        uninstall()
    }

    // MARK: - Internals

    private func install() {
        guard hotKeyRef == nil else { return }

        // Install the event handler first, then register the hotkey.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let r = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if r == noErr {
                    let me = Unmanaged<GlobalHotkeyService>
                        .fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in
                        me.fire()
                    }
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
        guard status == noErr else {
            logger.error("InstallEventHandler failed: \(status)")
            return
        }

        // ⌘⌥P — keyCode 35 (kVK_ANSI_P); modifiers = command + option.
        let keyCode: UInt32 = UInt32(kVK_ANSI_P)
        let mods: UInt32 = UInt32(cmdKey | optionKey)
        var hkID = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let reg = RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if reg != noErr {
            logger.error("RegisterEventHotKey failed: \(reg)")
            // Likely another app owns ⌘⌥P. Clean up partial install.
            if let h = eventHandler { RemoveEventHandler(h) }
            eventHandler = nil
            hotKeyRef = nil
        } else {
            logger.info("Global hotkey ⌘⌥P registered")
        }
    }

    private func uninstall() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        if let h = eventHandler { RemoveEventHandler(h) }
        eventHandler = nil
    }

    private func fire() {
        logger.info("Hotkey fired")
        onTrigger?()
    }
}
