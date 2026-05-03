import Foundation

/// Owns the user-issued one-off throttle escape hatch. Distinct from
/// the rule engine and the governor — this is the surface that fires
/// when the user explicitly says "cap this app for an hour" via the
/// menu bar button, the right-click quick menu, the URL scheme, or
/// the Shortcuts intent. Holds the auto-release timers and the
/// wall-clock deadlines the popover surfaces in its countdown.
///
/// Extracted from `ThermalStore` in v0.14.x post-release cleanup —
/// the store had grown into a god object with eight responsibilities
/// stacked into one type. The manual-throttle subsystem was the most
/// self-contained and the lowest risk to peel out first.
///
/// Lifecycle:
///   - Owned by `ThermalStore`. Has no `start()` / `stop()` of its
///     own — timers are per-throttle and self-cancelling.
///   - All public surface is `@MainActor`: the deadline dictionaries
///     are read directly by SwiftUI views, and the auto-release
///     tasks call back through the throttler from the main actor.
///
/// Keying:
///   - PID-keyed entries (`"pid:42"`) for `throttleFrontmost`
///   - Bundle-keyed entries (`"bundle:com.apple.safari"`) for
///     `throttleBundle`
///   - The two namespaces don't collide because of the prefix.
@MainActor
final class ManualThrottleCoordinator {
    /// Wall-clock deadlines for active manual throttles. Keys match
    /// `manualExpiryKey(...)`. `nil` deadline = "until I clear it"
    /// (very long durations are sentinel-converted to nil so the
    /// UI countdown reads as a static badge instead of a 30-day
    /// timer).
    private(set) var manualExpiryDeadlines: [String: Date] = [:]

    private let throttler: ProcessThrottler

    /// Reads the latest `RunningProcess` snapshot. Closed-over rather
    /// than passed in directly so the coordinator doesn't have to
    /// know about `ProcessSnapshotPublisher` — any source of "current
    /// processes" works here. ThermalStore wires it to
    /// `snapshots.latest`.
    private let snapshotProvider: () -> [RunningProcess]

    private var manualExpiryTasks: [String: Task<Void, Never>] = [:]

    init(throttler: ProcessThrottler,
         snapshotProvider: @escaping () -> [RunningProcess]) {
        self.throttler = throttler
        self.snapshotProvider = snapshotProvider
    }

    // MARK: - Key derivation

    private static func manualExpiryKey(pid: pid_t) -> String {
        "pid:\(pid)"
    }

    private static func manualExpiryKey(bundleID: String) -> String {
        "bundle:\(bundleID.lowercased())"
    }

    // MARK: - Query

    /// Returns the wall-clock deadline (if any) for a manual throttle
    /// on this PID. UI uses this for the countdown badge.
    func manualThrottleDeadline(pid: pid_t) -> Date? {
        manualExpiryDeadlines[Self.manualExpiryKey(pid: pid)]
    }

    // MARK: - Throttle / release

    /// Release a manual throttle on this PID and cancel its pending
    /// auto-release task. Use this from UI instead of calling
    /// `throttler.clearDuty` directly so the deadline tracker stays
    /// in sync.
    func releaseManualThrottle(pid: pid_t) {
        throttler.clearDuty(source: .manual, for: pid)
        let key = Self.manualExpiryKey(pid: pid)
        manualExpiryTasks[key]?.cancel()
        manualExpiryTasks[key] = nil
        manualExpiryDeadlines[key] = nil
    }

    /// Fire-and-forget cap on a specific PID via the `.manual` source.
    /// Used by the "Throttle frontmost at X%" quick-menu action.
    /// Bypasses the foreground-duty floor because the whole point is
    /// to rein in the app the user is currently interacting with.
    /// Auto-releases after `duration` (default 1h) so the user can't
    /// accidentally leave something pegged forever. Re-invoking
    /// replaces the cap.
    func throttleFrontmost(pid: pid_t,
                           name: String,
                           duty: Double,
                           duration: TimeInterval = 60 * 60) {
        guard pid > 0, pid != getpid() else { return }
        throttler.setDuty(duty, for: pid, name: name, source: .manual)

        let key = Self.manualExpiryKey(pid: pid)
        manualExpiryTasks[key]?.cancel()
        // Treat very long durations (≥ 30 days) as "until I clear it"
        // — no deadline shown in the UI countdown.
        manualExpiryDeadlines[key] = duration < 60 * 60 * 24 * 30
            ? Date().addingTimeInterval(duration)
            : nil
        manualExpiryTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.throttler.clearDuty(source: .manual, for: pid)
            self.manualExpiryTasks[key] = nil
            self.manualExpiryDeadlines[key] = nil
        }
    }

    /// URL-scheme / Shortcuts entry point: throttle every PID
    /// currently matching `bundleID` (case-insensitive) via `.manual`
    /// duty. Like `throttleFrontmost` but identifies the target by
    /// bundle instead of PID, so it survives the app being killed
    /// and re-launched within the duration (the next matching
    /// snapshot picks it up again).
    /// Returns the number of PIDs affected.
    @discardableResult
    func throttleBundle(bundleID: String,
                        duty: Double,
                        duration: TimeInterval = 60 * 60) -> Int {
        let target = bundleID.lowercased()
        let pids = snapshotProvider().filter {
            ($0.bundleID?.lowercased() == target) && $0.id > 0 && $0.id != getpid()
        }
        for p in pids {
            throttler.setDuty(duty, for: p.id, name: p.name, source: .manual)
        }
        // Auto-release after the duration. Clear by bundle so we
        // catch PIDs spawned after the initial call too. Cancel any
        // prior expiry for this bundle so back-to-back invocations
        // don't have an old sleeper clear the new cap.
        let key = Self.manualExpiryKey(bundleID: bundleID)
        manualExpiryTasks[key]?.cancel()
        manualExpiryDeadlines[key] = duration < 60 * 60 * 24 * 30
            ? Date().addingTimeInterval(duration)
            : nil
        manualExpiryTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.releaseBundle(bundleID: bundleID)
            self.manualExpiryTasks[key] = nil
            self.manualExpiryDeadlines[key] = nil
        }
        return pids.count
    }

    /// Cancel every pending auto-release task and clear the deadline
    /// map. Called from `ThermalStore.stop()` during app teardown so
    /// no dangling tasks survive the app's lifecycle. The throttler
    /// itself has already released every PID by the time this runs;
    /// this is hygiene, not safety.
    func shutdownAll() {
        for (_, task) in manualExpiryTasks { task.cancel() }
        manualExpiryTasks.removeAll()
        manualExpiryDeadlines.removeAll()
    }

    /// Release any manual throttles on processes matching `bundleID`.
    /// Called explicitly by URL scheme / Shortcuts, and automatically
    /// by the `throttleBundle` expiry timer. Also cancels any pending
    /// expiry task so an explicit release isn't followed by a stale
    /// auto-release firing later for the same bundle.
    @discardableResult
    func releaseBundle(bundleID: String) -> Int {
        let target = bundleID.lowercased()
        let pids = snapshotProvider()
            .filter { $0.bundleID?.lowercased() == target }
            .map { $0.id }
        for pid in pids {
            throttler.clearDuty(source: .manual, for: pid)
        }
        let key = Self.manualExpiryKey(bundleID: bundleID)
        manualExpiryTasks[key]?.cancel()
        manualExpiryTasks[key] = nil
        manualExpiryDeadlines[key] = nil
        return pids.count
    }
}
