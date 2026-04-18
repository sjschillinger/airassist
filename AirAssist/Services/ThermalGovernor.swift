import Foundation

/// System-wide cap enforcer. Combines user intent (`GovernorConfig`) with live
/// signals (hottest enabled sensor, total user CPU%) and applies throttling
/// via `ProcessThrottler`. Hysteresis prevents thrash: we start throttling
/// above the cap but only release once we're a configurable margin below it.
///
/// Targeting heuristic: when a cap is breached, take the top-N user
/// processes by CPU% (N = `maxTargets`) whose CPU% ≥ `minCPUForTargeting`,
/// and apply a duty that scales with how far over the cap we are.
@MainActor
final class ThermalGovernor {

    private let snapshots: ProcessSnapshotPublisher
    private let throttler: ProcessThrottler
    /// Called to ask "is this PID already covered by a user's per-app rule?"
    /// The governor refuses to touch rule-covered PIDs so the rule engine
    /// is the single authority for those. Nil → always false.
    var isRuleCoveredPID: ((pid_t) -> Bool)?

    /// Current live config — edited by UI through ThermalStore.
    var config: GovernorConfig

    /// True once we have crossed a cap and haven't released yet.
    private(set) var isTempThrottling: Bool = false
    private(set) var isCPUThrottling:  Bool = false

    /// Last-sampled total user CPU% across non-excluded processes.
    /// Updated each tick. 0 until the first tick completes.
    private(set) var lastTotalCPUPercent: Double = 0

    /// Last snapshot of top user processes by CPU%. Published each tick so
    /// UI surfaces (dashboard Top CPU panel) can share the governor's
    /// single sampling pass instead of double-sampling ProcessInspector
    /// (which would corrupt the delta-CPU state).
    private(set) var lastTopProcesses: [RunningProcess] = []

    /// Externally-set pause. When true the governor releases targets
    /// and sleeps until cleared. Set by ThermalStore on user-initiated
    /// "pause throttling" actions.
    var isPaused: Bool = false {
        didSet {
            if isPaused {
                releaseAllGovernorTargets()
                isTempThrottling = false
                isCPUThrottling  = false
            }
        }
    }

    /// PIDs the governor itself is managing (separate from per-app rules).
    private var governorPIDs: Set<pid_t> = []

    /// Closure to sample the "hottest enabled temperature" each tick.
    /// Supplied by ThermalStore so the governor doesn't depend on its internals.
    private let hottestTempC: () -> Double?

    init(snapshots: ProcessSnapshotPublisher,
         throttler: ProcessThrottler,
         config: GovernorConfig,
         hottestTempC: @escaping () -> Double?) {
        self.snapshots    = snapshots
        self.throttler    = throttler
        self.config       = config
        self.hottestTempC = hottestTempC
    }

    /// Release every PID the governor has requested. Called by ThermalStore
    /// on app teardown after the shared tick loop has stopped.
    func stop() {
        releaseAllGovernorTargets()
        isTempThrottling = false
        isCPUThrottling  = false
    }

    /// Drive a decision. Called by `ThermalStore` on its shared 1Hz tick
    /// after the snapshot publisher has already refreshed — that way both
    /// engines see identical process data for the same instant.
    func tick() {
        // Mirror the latest snapshot for UI consumers. Reading it through
        // the governor keeps the existing dashboard binding stable.
        lastTotalCPUPercent = snapshots.latestTotalCPU
        lastTopProcesses    = snapshots.latest
        let procs = snapshots.latest

        if isPaused { return }
        guard !config.isOff else {
            releaseAllGovernorTargets()
            isTempThrottling = false
            isCPUThrottling  = false
            return
        }

        let temp = hottestTempC()

        // --- temperature branch ---
        if config.tempEnabled, let t = temp {
            if t >= config.maxTempC {
                isTempThrottling = true
            } else if t <= config.maxTempC - config.tempHysteresisC {
                isTempThrottling = false
            }
        } else {
            isTempThrottling = false
        }

        // --- cpu branch ---
        let totalCPU = snapshots.latestTotalCPU
        if config.cpuEnabled {
            if totalCPU >= config.maxCPUPercent {
                isCPUThrottling = true
            } else if totalCPU <= config.maxCPUPercent - config.cpuHysteresisPercent {
                isCPUThrottling = false
            }
        } else {
            isCPUThrottling = false
        }

        if isTempThrottling || isCPUThrottling {
            // Compute how aggressive the throttle should be.
            // Further over the cap → lower duty.
            let tempOvershoot: Double = {
                guard isTempThrottling, let t = temp else { return 0 }
                return max(0, t - config.maxTempC)
            }()
            let cpuOvershoot: Double = {
                guard isCPUThrottling else { return 0 }
                return max(0, totalCPU - config.maxCPUPercent)
            }()
            // Normalise: 10°C over or 100% over ≈ full aggressive throttle.
            let tempFactor = min(1.0, tempOvershoot / 10.0)
            let cpuFactor  = min(1.0, cpuOvershoot  / 100.0)
            let aggression = max(tempFactor, cpuFactor)
            // duty ranges from 0.80 (mild) down to 0.20 (hard).
            let duty = 0.80 - (0.60 * aggression)

            applyThrottle(duty: duty, candidates: procs)
        } else {
            releaseAllGovernorTargets()
        }
    }

    /// Update live config; caller should persist separately.
    func updateConfig(_ newConfig: GovernorConfig) {
        self.config = newConfig
        if newConfig.isOff { releaseAllGovernorTargets() }
    }

    // MARK: - Private

    private func applyThrottle(duty: Double, candidates: [RunningProcess]) {
        let targets = candidates
            .filter { $0.cpuPercent >= config.minCPUForTargeting }
            // Skip PIDs already covered by a user's per-app rule — the rule
            // engine is the single authority there. Prevents a 1Hz duty
            // tug-of-war between the two systems.
            .filter { isRuleCoveredPID?($0.id) != true }
            .prefix(config.maxTargets)

        let wantedPIDs = Set(targets.map(\.id))

        // Withdraw governor's request from pids we no longer want (leave
        // any rule-engine request on those pids intact).
        for pid in governorPIDs.subtracting(wantedPIDs) {
            throttler.clearDuty(source: .governor, for: pid)
        }
        governorPIDs = wantedPIDs

        for p in targets {
            throttler.setDuty(duty, for: p.id, name: p.name, source: .governor)
        }
    }

    private func releaseAllGovernorTargets() {
        throttler.releaseSource(.governor)
        governorPIDs.removeAll()
    }
}
