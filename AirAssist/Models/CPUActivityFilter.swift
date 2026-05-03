import Foundation

/// Pure selection logic for the popover's CPU Activity panel.
/// Lives outside the SwiftUI view so the filter rules are unit-
/// testable without instantiating `ThermalStore`.
///
/// The contract: given a snapshot of running processes plus the
/// PIDs the rule engine and the manual-throttle source already
/// own, return the top-N rows the panel should render.
///
/// Filter order (also enforced by tests):
///   1. drop processes below the visibility floor (default 1% CPU)
///   2. drop processes already managed by a per-app rule
///   3. drop processes already running under a manual cap
///   4. drop self (don't suggest throttling Air Assist)
///   5. sort descending by `cpuPercent`
///   6. take prefix `limit` (default 5)
///
/// Each filter is a deliberate UX call — if you change one, the
/// matching test case will need an updated assertion.
enum CPUActivityFilter {

    /// Default visibility floor. Processes below this are noise.
    static let defaultMinCPUPercent: Double = 1.0

    /// Default panel size. Mirrors the size every comparable
    /// monitoring app uses for "top processes" — small enough to
    /// scan at a glance, big enough to surface the actual hogs.
    static let defaultLimit: Int = 5

    /// Apply the panel's selection rules to a process snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: the governor's `lastTopProcesses` (or any
    ///     equivalent recent snapshot)
    ///   - ruleManagedPIDs: PIDs the per-app rule engine is
    ///     currently managing — these have their own row
    ///     elsewhere in the popover
    ///   - manuallyThrottledPIDs: PIDs currently held under a
    ///     `.manual` cap — same reason
    ///   - selfPID: the host process (Air Assist itself)
    ///   - minCPUPercent: visibility floor (default 1%)
    ///   - limit: how many rows to return (default 5)
    static func topRows(
        from snapshot: [RunningProcess],
        ruleManagedPIDs: Set<pid_t>,
        manuallyThrottledPIDs: Set<pid_t>,
        selfPID: pid_t,
        minCPUPercent: Double = defaultMinCPUPercent,
        limit: Int = defaultLimit
    ) -> [RunningProcess] {
        snapshot
            .filter { $0.cpuPercent >= minCPUPercent }
            .filter { !ruleManagedPIDs.contains($0.id) }
            .filter { !manuallyThrottledPIDs.contains($0.id) }
            .filter { $0.id != selfPID }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { $0 }
    }
}
