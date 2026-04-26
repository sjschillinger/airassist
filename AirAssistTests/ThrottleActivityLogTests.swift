import XCTest
@testable import AirAssist

/// `ThrottleActivityLog` is what the dashboard's "Recent activity" panel
/// reads. Two behaviours matter and aren't obvious from the type:
///
///   1. **Coalescing**: the cycler reapplies its duty every tick. If
///      every reapply produced a log entry, the buffer would drown in
///      duplicates and the panel would scroll uselessly fast.
///   2. **Capacity**: it's a ring — newest first, oldest dropped — so
///      the panel can render `entries` without an explicit window.
///
/// Both are easy to regress in a refactor (e.g. someone changes the
/// duplicate-detection key) and silently degrade UX. Pin them here.
@MainActor
final class ThrottleActivityLogTests: XCTestCase {

    func testEmptyAtStart() {
        let log = ThrottleActivityLog()
        XCTAssertEqual(log.entries.count, 0)
    }

    func testRecordPrependsNewestFirst() {
        let log = ThrottleActivityLog()
        log.record(kind: .apply, source: .governor, pid: 100, name: "alpha", duty: 0.5)
        log.record(kind: .apply, source: .governor, pid: 200, name: "beta",  duty: 0.5)
        // Newest first.
        XCTAssertEqual(log.entries.first?.name, "beta")
        XCTAssertEqual(log.entries.last?.name,  "alpha")
        XCTAssertEqual(log.entries.count, 2)
    }

    func testCoalescesIdenticalConsecutiveApply() {
        // Same (kind, source, pid, duty) back-to-back must collapse.
        let log = ThrottleActivityLog()
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5)
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5)
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5)
        XCTAssertEqual(log.entries.count, 1)
    }

    func testDifferentDutyBreaksCoalescing() {
        // The cycler legitimately changes duty as the governor reacts.
        // Those transitions should land as separate entries.
        let log = ThrottleActivityLog()
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5)
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.3)
        XCTAssertEqual(log.entries.count, 2)
    }

    func testTinyDutyDeltaIsCoalesced() {
        // 0.005 epsilon: floating noise from `min(duty)` arbitration
        // shouldn't fragment the log.
        let log = ThrottleActivityLog()
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5)
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5004)
        XCTAssertEqual(log.entries.count, 1)
    }

    func testDifferentSourceBreaksCoalescing() {
        // .governor and .rule both targeting the same pid is a real
        // arbitration situation worth seeing in the log.
        let log = ThrottleActivityLog()
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5)
        log.record(kind: .apply, source: .rule,     pid: 42, name: "x", duty: 0.5)
        XCTAssertEqual(log.entries.count, 2)
    }

    func testApplyThenReleaseAreDistinct() {
        // .apply followed by .release of the same pid must produce two
        // entries — that's the most informative case for the panel.
        let log = ThrottleActivityLog()
        log.record(kind: .apply,   source: .governor, pid: 42, name: "x", duty: 0.5)
        log.record(kind: .release, source: .governor, pid: 42, name: "x", duty: 1.0)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.first?.kind, .release)
    }

    func testCapacityIsBounded() {
        // The class is documented as capped (currently 80). Drive past
        // the cap with diverse entries (different pids defeat coalescing)
        // and confirm we don't grow unbounded.
        let log = ThrottleActivityLog()
        for pid in 1...200 {
            log.record(kind: .apply, source: .governor,
                       pid: pid_t(pid), name: "p\(pid)", duty: 0.5)
        }
        XCTAssertLessThanOrEqual(log.entries.count, 100,
                                 "Activity log grew unbounded — capacity check broke")
        // And the newest survived (we wrote pid 200 last).
        XCTAssertEqual(log.entries.first?.pid, 200)
    }

    func testClearEmptiesBuffer() {
        let log = ThrottleActivityLog()
        log.record(kind: .apply, source: .governor, pid: 42, name: "x", duty: 0.5)
        log.clear()
        XCTAssertEqual(log.entries.count, 0)
    }
}
