import Foundation

/// Single source of truth for "what's running and how much CPU is it using."
/// Both the `ThermalGovernor` and the `ThrottleRuleEngine` consume the same
/// snapshot each tick instead of double-sampling the underlying
/// `ProcessInspector` (each snapshot resets the CPU% delta window, so two
/// samples/sec with staggered timing would produce noisier CPU numbers than
/// necessary).
///
/// Driven by `ThermalStore`'s 1Hz timer. Anyone who needs live process data
/// reads `latest` / `latestTotalCPU`.
@MainActor
final class ProcessSnapshotPublisher {

    private let inspector: ProcessInspector

    /// Processes owned by the current user, sorted high→low by CPU%.
    /// Updated every `refresh()`. Excluded-name filter is applied.
    private(set) var latest: [RunningProcess] = []

    /// Total CPU% summed across `latest`. Handy for governor's CPU cap.
    private(set) var latestTotalCPU: Double = 0

    /// Timestamp of the last successful refresh.
    private(set) var lastRefresh: Date?

    init(inspector: ProcessInspector) {
        self.inspector = inspector
    }

    /// Take a fresh snapshot. Call once per governor/rule tick from a single
    /// driver (ThermalStore).
    @discardableResult
    func refresh() -> [RunningProcess] {
        let procs = inspector.topUserProcessesByCPU(limit: 50, minPercent: 0.0)
        latest = procs
        latestTotalCPU = procs.reduce(0.0) { $0 + $1.cpuPercent }
        lastRefresh = Date()
        return procs
    }
}
