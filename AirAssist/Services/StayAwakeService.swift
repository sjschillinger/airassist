import Foundation
import IOKit
import IOKit.pwr_mgt

/// Keeps the Mac awake via IOKit power assertions — `caffeinate(1)`-style,
/// but with finer-grained modes and an optional "display-awake for N
/// minutes, then allow display sleep" timer.
///
/// Assertions are the *public* API for this; no entitlements required,
/// no helper. macOS cleans them up automatically if our process exits or
/// crashes (same kernel cleanup that `caffeinate(1)` relies on), so we
/// can't accidentally pin the Mac awake forever. The SafetyCoordinator
/// still releases on `stop()` for politeness.
///
/// Modes:
///   - `.off`                 — no assertion held.
///   - `.system`              — prevent system idle sleep; display may
///                              sleep as normal (useful for downloads,
///                              background renders on battery).
///   - `.display`             — prevent display *and* system sleep; the
///                              screen stays lit.
///   - `.displayThenSystem(minutes:)` — display stays on for N minutes,
///                              then the assertion downgrades to system-only
///                              so the screen can sleep while work
///                              continues.
///
/// The enum is the single source of truth. Whenever `currentMode` is
/// set, the existing assertion is released and a fresh one taken to
/// match. This keeps the IOKit state in lock-step with the UI.
@Observable
@MainActor
final class StayAwakeService {

    enum Mode: Equatable, Codable {
        case off
        case system
        case display
        case displayThenSystem(minutes: Int)

        /// String tag for persistence — the `minutes` payload is stored
        /// separately so UserDefaults remains forward-compatible if we
        /// add more variants.
        var storageTag: String {
            switch self {
            case .off:                return "off"
            case .system:             return "system"
            case .display:            return "display"
            case .displayThenSystem:  return "displayThenSystem"
            }
        }

        var isActive: Bool { self != .off }

        /// Short label for menu ✓ rows.
        var menuLabel: String {
            switch self {
            case .off:                       return "Off"
            case .system:                    return "Keep system awake (allow display sleep)"
            case .display:                   return "Keep system & display awake"
            case .displayThenSystem(let m):  return "Keep display awake for \(m) min, then system only"
            }
        }
    }

    // MARK: - Public state (Observable for SwiftUI)

    /// The mode the user selected. Setting this applies the change
    /// immediately; callers don't need to call anything else.
    private(set) var currentMode: Mode = .off

    /// True while any assertion is held. Cheaper than comparing modes.
    var isActive: Bool { assertionID != nil }

    /// Remaining seconds before the display-asleep downgrade fires.
    /// `nil` when no timer is active. Updated by a lightweight 1Hz tick
    /// so the UI can show a countdown.
    private(set) var displayTimerRemaining: TimeInterval?

    // MARK: - Private

    private var assertionID: IOPMAssertionID?
    private var assertionType: String?
    private var downgradeTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var downgradeDeadline: Date?

    private let assertionName = "Air Assist — Stay Awake" as CFString

    // MARK: - API

    /// Apply a new mode. Safe to call repeatedly with the same mode
    /// (no-op after the first call for that mode).
    func setMode(_ mode: Mode) {
        guard mode != currentMode else { return }
        releaseAssertion()
        cancelDowngrade()

        currentMode = mode

        switch mode {
        case .off:
            break

        case .system:
            takeAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep)

        case .display:
            takeAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep)

        case .displayThenSystem(let minutes):
            takeAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
            scheduleDowngrade(after: TimeInterval(minutes) * 60)
        }
    }

    /// Release everything — called from `ThermalStore.stop()` on quit.
    /// macOS would clean the assertion up on process exit anyway, but
    /// being explicit keeps the state machine tidy.
    func shutdown() {
        cancelDowngrade()
        releaseAssertion()
        currentMode = .off
    }

    // MARK: - IOKit assertion plumbing

    private func takeAssertion(type: String) {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionName,
            &id
        )
        guard result == kIOReturnSuccess else {
            assertionID = nil
            assertionType = nil
            return
        }
        assertionID = id
        assertionType = type
    }

    private func releaseAssertion() {
        if let id = assertionID {
            IOPMAssertionRelease(id)
        }
        assertionID = nil
        assertionType = nil
    }

    // MARK: - Timed downgrade (display → system-only)

    private func scheduleDowngrade(after delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(delay)
        downgradeDeadline = deadline
        displayTimerRemaining = delay

        // Downgrade fires once at `delay`; countdown refreshes `displayTimerRemaining` every second.
        downgradeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.downgradeDeadline == deadline else { return }  // superseded
            self.downgradeNow()
        }

        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let d = self.downgradeDeadline else { return }
                let remaining = d.timeIntervalSinceNow
                if remaining <= 0 {
                    self.displayTimerRemaining = nil
                    return
                }
                self.displayTimerRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func downgradeNow() {
        releaseAssertion()
        takeAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        downgradeDeadline = nil
        displayTimerRemaining = nil
        // currentMode stays .displayThenSystem(minutes:) so the UI still
        // shows the user what they chose; the underlying assertion type
        // is the only thing that changed.
    }

    private func cancelDowngrade() {
        downgradeTask?.cancel()
        downgradeTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        downgradeDeadline = nil
        displayTimerRemaining = nil
    }
}

// MARK: - Persistence

/// Persists the last-selected mode so toggling back on after a quit
/// restores whatever the user had configured. Kept separate from the
/// service so tests can construct a bare service without touching
/// UserDefaults.
enum StayAwakePersistence {
    private static let modeKey = "stayAwake.mode"
    private static let minutesKey = "stayAwake.displayTimeoutMinutes"

    static func load() -> StayAwakeService.Mode {
        let defaults = UserDefaults.standard
        let tag = defaults.string(forKey: modeKey) ?? "off"
        switch tag {
        case "system":            return .system
        case "display":           return .display
        case "displayThenSystem":
            let m = defaults.integer(forKey: minutesKey)
            return .displayThenSystem(minutes: m > 0 ? m : 10)
        default:                  return .off
        }
    }

    static func save(_ mode: StayAwakeService.Mode) {
        let defaults = UserDefaults.standard
        defaults.set(mode.storageTag, forKey: modeKey)
        if case .displayThenSystem(let m) = mode {
            defaults.set(m, forKey: minutesKey)
        }
    }
}
