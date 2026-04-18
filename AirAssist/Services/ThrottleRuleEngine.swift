import Foundation

/// Applies user-defined per-app `ThrottleRule`s each tick. For every running
/// process that matches an enabled rule, we push the rule's duty into the
/// `ProcessThrottler`. PIDs no longer matching any rule are released.
///
/// This is distinct from `ThermalGovernor`: rules are user-defined static
/// per-app caps ("always throttle Electron app X to 50%"), whereas the
/// governor reacts to live system signals. They share the same
/// `ProcessThrottler` but track their own target sets independently.
@MainActor
final class ThrottleRuleEngine {

    private let snapshots: ProcessSnapshotPublisher
    private let inspector: ProcessInspector   // for the Add-rule picker only
    private let throttler: ProcessThrottler

    /// Currently loaded user rules.
    var config: ThrottleRulesConfig

    /// PIDs the rule engine is currently managing.
    private(set) var managedPIDs: Set<pid_t> = []

    /// Per-rule lifetime statistics for the current day. Reset at midnight
    /// (local) on first tick that crosses the day boundary. Exposed to the
    /// Throttling preferences UI so users can see "Chrome Helper fired 14×
    /// today, 3m 20s total" without digging into the history log.
    struct RuleStats {
        /// Number of times the rule transitioned from "no matching PIDs"
        /// to "at least one matching PID" since the stats day started.
        /// Counts distinct episodes, not seconds.
        var fires: Int = 0
        /// Accumulated seconds the rule had ≥1 matching PID. Each tick is
        /// ~1s per the shared control loop; the engine assumes 1s per tick
        /// rather than measuring wall time so a paused app doesn't falsely
        /// grow throttle time when it isn't actually being stopped.
        var throttleSeconds: TimeInterval = 0
    }
    private(set) var stats: [ThrottleRule.ID: RuleStats] = [:]
    /// Which rules had ≥1 matching PID on the previous tick, for edge-
    /// detecting fire transitions (0→>0).
    private var previouslyFiring: Set<ThrottleRule.ID> = []
    /// Stats are reset when we see a tick whose day-of-year differs from
    /// this anchor. Nil means "reset on the next tick".
    private var statsDayAnchor: Date?

    /// Externally-set pause. When true the engine releases everything
    /// and skips its tick.
    var isPaused: Bool = false {
        didSet { if isPaused { releaseAll() } }
    }

    init(snapshots: ProcessSnapshotPublisher,
         inspector: ProcessInspector,
         throttler: ProcessThrottler,
         config: ThrottleRulesConfig) {
        self.snapshots = snapshots
        self.inspector = inspector
        self.throttler = throttler
        self.config    = config
    }

    /// Release every PID the rule engine has requested. Called by
    /// ThermalStore on teardown after the shared tick loop has stopped.
    func stop() {
        releaseAll()
    }

    func updateConfig(_ newConfig: ThrottleRulesConfig) {
        self.config = newConfig
        if !newConfig.enabled { releaseAll() }
    }

    /// List all currently running processes with bundle info, for the UI's
    /// "Add rule for this app" flow. Filters obvious noise. This is the only
    /// place we still call `inspector.snapshot()` ad-hoc — it doesn't
    /// participate in the shared 1Hz tick.
    func availableProcesses() -> [RunningProcess] {
        inspector.snapshot()
            .filter { $0.isCurrentUser }
            .filter { !ProcessInspector.excludedNames.contains($0.name) }
    }

    func tick() {
        if isPaused { return }
        guard config.enabled else {
            releaseAll()
            return
        }

        resetStatsIfNewDay()

        let procs = snapshots.latest

        var wanted: [pid_t: (duty: Double, name: String)] = [:]
        // Track which rules had ≥1 match this tick, to update stats below.
        var firingThisTick: Set<ThrottleRule.ID> = []
        for p in procs {
            if let rule = config.rule(for: p) {
                wanted[p.id] = (rule.duty, p.name)
                firingThisTick.insert(rule.id)
            }
        }

        // Update stats: +1 fire on 0→≥1 transition; +1s throttle while firing.
        for id in firingThisTick {
            var s = stats[id] ?? RuleStats()
            if !previouslyFiring.contains(id) { s.fires += 1 }
            s.throttleSeconds += 1
            stats[id] = s
        }
        previouslyFiring = firingThisTick

        // Withdraw our source from pids that no longer match a rule.
        for pid in managedPIDs where wanted[pid] == nil {
            throttler.clearDuty(source: .rule, for: pid)
        }
        managedPIDs = Set(wanted.keys)

        for (pid, spec) in wanted {
            throttler.setDuty(spec.duty, for: pid, name: spec.name, source: .rule)
        }
    }

    /// Clears `stats` when the local calendar day changes. "Today" counts
    /// resetting at midnight matches the user's intuition better than
    /// rolling 24h windows.
    private func resetStatsIfNewDay() {
        let now = Date()
        let cal = Calendar.current
        if let anchor = statsDayAnchor,
           cal.isDate(anchor, inSameDayAs: now) {
            return
        }
        stats.removeAll()
        previouslyFiring.removeAll()
        statsDayAnchor = now
    }

    private func releaseAll() {
        throttler.releaseSource(.rule)
        managedPIDs.removeAll()
    }
}
