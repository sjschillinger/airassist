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

    /// Short plain-language explanation of why the governor is (or isn't)
    /// throttling right now. Updated each tick. Used by dashboard + popover
    /// to answer the "why is this happening" question without forcing the
    /// user to reason about caps and live values themselves.
    private(set) var reason: String = ""

    /// Last snapshot of top user processes by CPU%. Published each tick so
    /// UI surfaces (dashboard Top CPU panel) can share the governor's
    /// single sampling pass instead of double-sampling ProcessInspector
    /// (which would corrupt the delta-CPU state).
    private(set) var lastTopProcesses: [RunningProcess] = []

    /// Rolling CPU% history keyed by rule identity (bundleID when available,
    /// else process name). Used by the UI's empty-rules suggestions panel
    /// to surface apps that have been *sustaining* high CPU — not just
    /// spiky, one-tick blips. Window is `sustainedWindowSec` samples long
    /// (one per tick ≈ 1s).
    private var cpuHistoryByKey: [String: (samples: [Double], lastSeen: RunningProcess)] = [:]
    /// Number of recent samples kept per identity. 30 ≈ 30 seconds at the
    /// shared 1Hz tick. Longer windows filter spikes better but delay
    /// surfacing of genuinely-new hot apps.
    static let sustainedWindowSec: Int = 30
    /// Minimum windowed-average CPU% for "this is worth suggesting a rule
    /// for". 40% is ~half a core on average over 30s — enough that the
    /// user is likely to feel it in battery or fan behavior.
    static let sustainedThresholdPct: Double = 40

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

    /// Closure to sample "is the Mac on battery right now" each tick.
    /// Injected so the governor stays unit-testable without IOKit.
    /// Conservative default: always `false` (treated as AC) if the
    /// store doesn't supply one — preserves pre-`onBatteryOnly`
    /// behaviour for any code path that builds a governor directly.
    private let isOnBattery: () -> Bool

    /// Closure to sample `ProcessInfo.processInfo.thermalState`. Injected
    /// so tests can drive the aggression path without poking the real
    /// OS signal. Default reads live from the process.
    private let osThermalState: () -> ProcessInfo.ThermalState

    init(snapshots: ProcessSnapshotPublisher,
         throttler: ProcessThrottler,
         config: GovernorConfig,
         hottestTempC: @escaping () -> Double?,
         isOnBattery: @escaping () -> Bool = { false },
         osThermalState: @escaping () -> ProcessInfo.ThermalState = {
             ProcessInfo.processInfo.thermalState
         }) {
        self.snapshots      = snapshots
        self.throttler      = throttler
        self.config         = config
        self.hottestTempC   = hottestTempC
        self.isOnBattery    = isOnBattery
        self.osThermalState = osThermalState
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
        updateCPUHistory(procs: procs)

        if isPaused { return }
        guard !config.isOff else {
            releaseAllGovernorTargets()
            isTempThrottling = false
            isCPUThrottling  = false
            return
        }

        // "Throttle only on battery" gate. When enabled + on AC, the
        // governor is armed-but-silent: targets released, flags cleared,
        // reason surfaces why so the user isn't confused by an "Armed"
        // status that never fires. When on battery, fall through to the
        // normal cap check.
        if config.onBatteryOnly && !isOnBattery() {
            releaseAllGovernorTargets()
            isTempThrottling = false
            isCPUThrottling  = false
            reason = "Idle · on AC (on-battery-only is on)"
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

        // Update narrative — done regardless of whether we end up applying
        // a throttle this tick so "Armed" also gets a reason.
        reason = Self.describe(
            config: config,
            temp: temp,
            totalCPU: totalCPU,
            isTemp: isTempThrottling,
            isCPU: isCPUThrottling
        )

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
            // OS-level thermal-state bias. When macOS itself is already
            // reporting thermal pressure, we bias toward harder throttling
            // so we catch the runaway before the SoC self-throttles into
            // a slideshow. Mapping: nominal 0, fair 0.25, serious 0.6,
            // critical 1.0. Conservative — nominal contributes nothing, so
            // the feature can never make a cool machine throttle harder
            // than the live temp/CPU overshoot would warrant on its own.
            let osFactor: Double = config.respectOSThermalState
                ? Self.biasFor(osThermalState())
                : 0
            let aggression = max(tempFactor, cpuFactor, osFactor)
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
            // User-protected names (Xcode, terminals, the agent
            // running this session, etc.) can appear in the snapshot
            // because visibility surfaces want to show them, but the
            // governor must never SIGSTOP them. Belt-and-braces with
            // ProcessThrottler.setDuty's own protected-names refusal,
            // since dropping the candidate here also avoids the
            // log-spam from setDuty rejecting it every tick.
            .filter { !ProcessInspector.isProtected($0.name) }
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

    /// Append the current CPU% of every seen process to its rolling
    /// window, create windows for newly-seen identities, and drop any
    /// identity we haven't seen this tick (process ended).
    private func updateCPUHistory(procs: [RunningProcess]) {
        var seenKeys: Set<String> = []
        for p in procs {
            let key = ThrottleRule.key(for: p)
            seenKeys.insert(key)
            var entry = cpuHistoryByKey[key] ?? (samples: [], lastSeen: p)
            entry.samples.append(p.cpuPercent)
            if entry.samples.count > Self.sustainedWindowSec {
                entry.samples.removeFirst(entry.samples.count - Self.sustainedWindowSec)
            }
            entry.lastSeen = p
            cpuHistoryByKey[key] = entry
        }
        // Evict identities that disappeared — prevents unbounded growth
        // when short-lived processes (shell one-shots, test runs) churn.
        for k in cpuHistoryByKey.keys where !seenKeys.contains(k) {
            cpuHistoryByKey.removeValue(forKey: k)
        }
    }

    /// Processes whose windowed-average CPU% exceeds `sustainedThresholdPct`
    /// AND have been observed for at least half the window. Sorted by
    /// average CPU descending. Used by the empty-rules suggestions panel.
    var sustainedHighCPUCandidates: [RunningProcess] {
        let minSamples = Self.sustainedWindowSec / 2
        return cpuHistoryByKey.values
            .filter { $0.samples.count >= minSamples }
            .compactMap { entry -> (avg: Double, proc: RunningProcess)? in
                let avg = entry.samples.reduce(0, +) / Double(entry.samples.count)
                guard avg >= Self.sustainedThresholdPct else { return nil }
                return (avg, entry.lastSeen)
            }
            .sorted { $0.avg > $1.avg }
            .map { $0.proc }
    }

    /// Map `ProcessInfo.ThermalState` to a `[0, 1]` aggression bias.
    /// Static + pure for unit-test visibility. `nonisolated` because
    /// it touches no state — the whole class is `@MainActor` otherwise.
    nonisolated static func biasFor(_ state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal:  return 0.0
        case .fair:     return 0.25
        case .serious:  return 0.6
        case .critical: return 1.0
        @unknown default: return 0.0
        }
    }

    private func releaseAllGovernorTargets() {
        throttler.releaseSource(.governor)
        governorPIDs.removeAll()
    }

    /// Build the user-facing narrative string. Kept static + pure so it's
    /// trivially unit-testable in isolation from the tick loop.
    private static func describe(
        config: GovernorConfig,
        temp: Double?,
        totalCPU: Double,
        isTemp: Bool,
        isCPU: Bool
    ) -> String {
        if config.isOff { return "Off" }
        // Active throttling — most specific reason wins.
        if isTemp, let t = temp {
            let over = Int((t - config.maxTempC).rounded())
            return "Temperature \(Int(t))°C > cap \(Int(config.maxTempC))°C (+\(over)°C)"
        }
        if isCPU {
            let over = Int((totalCPU - config.maxCPUPercent).rounded())
            return "CPU \(Int(totalCPU))% > cap \(Int(config.maxCPUPercent))% (+\(over)%)"
        }
        // Armed — show the tightest margin so the user knows which cap
        // will fire first.
        var notes: [String] = []
        if config.tempEnabled, let t = temp {
            let margin = Int((config.maxTempC - t).rounded())
            notes.append("temp \(Int(t))/\(Int(config.maxTempC))°C (−\(margin)°C)")
        }
        if config.cpuEnabled {
            let margin = Int((config.maxCPUPercent - totalCPU).rounded())
            notes.append("cpu \(Int(totalCPU))/\(Int(config.maxCPUPercent))% (−\(margin)%)")
        }
        return notes.isEmpty ? "Armed" : "Armed · " + notes.joined(separator: ", ")
    }
}
