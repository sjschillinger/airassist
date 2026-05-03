import XCTest
@testable import AirAssist

/// Locks in the contract for the popover's CPU Activity panel —
/// every filter rule is a UX call. If these tests need updating,
/// the panel's rules are about to change in a way users will see.
final class CPUActivityFilterTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal `RunningProcess` builder for these tests. We don't
    /// need realistic data for memory / paths / cpu time — only
    /// the fields the filter actually reads (`id`, `cpuPercent`).
    private func proc(_ pid: pid_t, _ cpuPercent: Double, name: String = "test") -> RunningProcess {
        RunningProcess(
            id: pid,
            name: name,
            bundleID: nil,
            executablePath: nil,
            parentPID: 1,
            uid: 501,
            isCurrentUser: true,
            cpuTimeNs: 0,
            cpuPercent: cpuPercent,
            rssBytes: 0
        )
    }

    // MARK: - Visibility floor

    func testDropsProcessesBelowFloor() {
        let snapshot = [
            proc(101, 50.0),
            proc(102, 0.5),    // below default 1.0 floor
            proc(103, 0.99),   // below default 1.0 floor
            proc(104, 1.0),    // exactly at floor — keep
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [],
            selfPID: 999
        )
        XCTAssertEqual(rows.map(\.id), [101, 104])
    }

    func testCustomFloorOverridesDefault() {
        let snapshot = [
            proc(101, 25.0),
            proc(102, 10.0),   // gets dropped at floor=20
            proc(103, 50.0),
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [],
            selfPID: 999,
            minCPUPercent: 20.0
        )
        XCTAssertEqual(rows.map(\.id), [103, 101])
    }

    // MARK: - Exclude rule-managed

    func testExcludesRuleManagedPIDs() {
        let snapshot = [
            proc(101, 80.0),
            proc(102, 60.0),
            proc(103, 40.0),
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [102],   // rule already covers this
            manuallyThrottledPIDs: [],
            selfPID: 999
        )
        XCTAssertEqual(rows.map(\.id), [101, 103])
    }

    // MARK: - Exclude manually throttled

    func testExcludesManuallyThrottledPIDs() {
        let snapshot = [
            proc(101, 80.0),
            proc(102, 60.0),
            proc(103, 40.0),
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [101],   // manual cap on this
            selfPID: 999
        )
        XCTAssertEqual(rows.map(\.id), [102, 103])
    }

    // MARK: - Exclude self

    func testExcludesSelfPID() {
        let snapshot = [
            proc(101, 80.0),
            proc(999, 60.0),   // pretending Air Assist itself is busy
            proc(103, 40.0),
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [],
            selfPID: 999
        )
        XCTAssertEqual(rows.map(\.id), [101, 103])
    }

    // MARK: - Ordering

    func testSortsDescendingByCPU() {
        let snapshot = [
            proc(101, 30.0),
            proc(102, 80.0),
            proc(103, 50.0),
            proc(104, 10.0),
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [],
            selfPID: 999
        )
        XCTAssertEqual(rows.map(\.id), [102, 103, 101, 104])
    }

    // MARK: - Limit

    func testTakesAtMostFiveByDefault() {
        let snapshot = (1...20).map { proc(pid_t($0), Double($0) * 5) }
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [],
            selfPID: 999
        )
        XCTAssertEqual(rows.count, 5)
        // Top 5 by CPU descending = pids 20, 19, 18, 17, 16
        XCTAssertEqual(rows.map(\.id), [20, 19, 18, 17, 16])
    }

    func testCustomLimitOverridesDefault() {
        let snapshot = (1...10).map { proc(pid_t($0), Double($0) * 5) }
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [],
            selfPID: 999,
            limit: 3
        )
        XCTAssertEqual(rows.map(\.id), [10, 9, 8])
    }

    // MARK: - Compounding filters

    func testAllFiltersTogether() {
        // 8 processes, varied CPUs, various exclusions.
        let snapshot = [
            proc(101, 90.0),         // top — keep
            proc(102, 80.0),         // rule-managed — drop
            proc(103, 70.0),         // manually throttled — drop
            proc(104, 60.0),         // self — drop
            proc(105, 50.0),         // keep
            proc(106, 40.0),         // keep
            proc(107, 0.5),          // below floor — drop
            proc(108, 30.0),         // keep
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [102],
            manuallyThrottledPIDs: [103],
            selfPID: 104
        )
        XCTAssertEqual(rows.map(\.id), [101, 105, 106, 108])
    }

    // MARK: - Edge cases

    func testEmptySnapshotReturnsEmpty() {
        let rows = CPUActivityFilter.topRows(
            from: [],
            ruleManagedPIDs: [],
            manuallyThrottledPIDs: [],
            selfPID: 999
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testAllProcessesFilteredOutReturnsEmpty() {
        let snapshot = [
            proc(101, 0.5),    // below floor
            proc(102, 80.0),   // rule-managed
        ]
        let rows = CPUActivityFilter.topRows(
            from: snapshot,
            ruleManagedPIDs: [102],
            manuallyThrottledPIDs: [],
            selfPID: 999
        )
        XCTAssertTrue(rows.isEmpty)
    }
}
