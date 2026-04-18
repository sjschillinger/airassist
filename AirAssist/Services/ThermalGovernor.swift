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

    private let inspector: ProcessInspector
    private let throttler: ProcessThrottler

    /// Current live config — edited by UI through ThermalStore.
    var config: GovernorConfig

    /// True once we have crossed a cap and haven't released yet.
    private(set) var isTempThrottling: Bool = false
    private(set) var isCPUThrottling:  Bool = false

    /// Last-sampled total user CPU% across non-excluded processes.
    /// Updated each tick. 0 until the first tick completes.
    private(set) var lastTotalCPUPercent: Double = 0

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

    private var tickTask: Task<Void, Never>?

    init(inspector: ProcessInspector,
         throttler: ProcessThrottler,
         config: GovernorConfig,
         hottestTempC: @escaping () -> Double?) {
        self.inspector    = inspector
        self.throttler    = throttler
        self.config       = config
        self.hottestTempC = hottestTempC
    }

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                self.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        releaseAllGovernorTargets()
        isTempThrottling = false
        isCPUThrottling  = false
    }

    /// One decision cycle: sample, decide, act.
    func tick() {
        if isPaused { return }
        guard !config.isOff else {
            releaseAllGovernorTargets()
            isTempThrottling = false
            isCPUThrottling  = false
            return
        }

        let procs = inspector.topUserProcessesByCPU(
            limit: 50,
            minPercent: 0.0
        )
        let totalCPU = procs.reduce(0.0) { $0 + $1.cpuPercent }
        lastTotalCPUPercent = totalCPU
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
            .prefix(config.maxTargets)

        let wantedPIDs = Set(targets.map(\.id))

        // Release any pids we were throttling that aren't in the new target set.
        for pid in governorPIDs.subtracting(wantedPIDs) {
            throttler.release(pid: pid)
        }
        governorPIDs = wantedPIDs

        for p in targets {
            throttler.setDuty(duty, for: p.id, name: p.name)
        }
    }

    private func releaseAllGovernorTargets() {
        for pid in governorPIDs {
            throttler.release(pid: pid)
        }
        governorPIDs.removeAll()
    }
}
