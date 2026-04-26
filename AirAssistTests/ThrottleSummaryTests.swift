import XCTest
@testable import AirAssist

/// `ThrottleSummary.aggregate` is the only thing the dashboard's
/// "This week" panel renders, so its math has to stand up to weird
/// log shapes the real on-disk file actually produces:
///
///   * episodes that span the window boundary (clamp, not drop),
///   * `apply` re-issues from the cycler that don't open a new episode,
///   * `release` events that arrive after `windowEnd` (clamp to end),
///   * `apply` events with no matching `release` because the app is
///     still throttled at render time (close at windowEnd),
///   * out-of-order events from a corrupted line midway through (the
///     defensive sort inside aggregate has to handle this).
///
/// Pin the behaviour here — the panel reads numbers off this struct
/// and a regression silently misreports user-facing totals.
final class ThrottleSummaryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ delta: TimeInterval) -> Date { t0.addingTimeInterval(delta) }

    private func event(_ kind: ThrottleEvent.Kind,
                       _ source: ThrottleEvent.Source = .governor,
                       _ name: String = "x",
                       _ delta: TimeInterval,
                       duty: Double = 0.5,
                       pid: Int32 = 100) -> ThrottleEvent {
        ThrottleEvent(timestamp: at(delta),
                      kind: kind, source: source,
                      pid: pid, name: name, duty: duty)
    }

    // MARK: - Empty / trivial

    func testEmptyWindowZeroes() {
        let s = ThrottleSummary.aggregate([], windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.totalEpisodes, 0)
        XCTAssertEqual(s.totalThrottleSeconds, 0)
        XCTAssertTrue(s.byApp.isEmpty)
    }

    func testApplyReleasePairCounts() {
        let evs = [
            event(.apply,   .governor, "x",   10),
            event(.release, .governor, "x",   70),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.totalEpisodes, 1)
        XCTAssertEqual(s.totalThrottleSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(s.byApp.first?.name, "x")
        XCTAssertEqual(s.byApp.first?.episodes, 1)
        XCTAssertEqual(s.bySource[.governor] ?? -1, 60, accuracy: 0.001)
    }

    // MARK: - Re-issue / coalescing

    func testRepeatedApplyDoesNotOpenSecondEpisode() {
        // The cycler reapplies its duty every tick. Aggregator must
        // treat a second `.apply` while a key is open as a continuation.
        let evs = [
            event(.apply,   .governor, "x",   10),
            event(.apply,   .governor, "x",   20),
            event(.apply,   .governor, "x",   30),
            event(.release, .governor, "x",   70),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.totalEpisodes, 1)
        XCTAssertEqual(s.totalThrottleSeconds, 60, accuracy: 0.001)
    }

    // MARK: - Open episodes

    func testOpenEpisodeClosedAtWindowEnd() {
        // Apply with no release before windowEnd → episode duration is
        // (windowEnd − apply).
        let evs = [
            event(.apply, .governor, "x", 100),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(160))
        XCTAssertEqual(s.totalEpisodes, 1)
        XCTAssertEqual(s.totalThrottleSeconds, 60, accuracy: 0.001)
    }

    // MARK: - Window clamping

    func testApplyBeforeWindowReleaseInsideClampsStart() {
        // Episode started before windowStart; only the in-window portion
        // counts. No new episode is counted (apply was pre-window) but
        // the seconds inside the window should still appear.
        let evs = [
            event(.apply,   .governor, "x",  -100),
            event(.release, .governor, "x",   50),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.totalEpisodes, 0,
                       "apply landed outside the window — should not count as new episode")
        XCTAssertEqual(s.totalThrottleSeconds, 50, accuracy: 0.001,
                       "seconds inside [windowStart, release) should still tally")
    }

    func testReleaseAfterWindowClampsToEnd() {
        // Apply inside window, release way past windowEnd → clamp.
        let evs = [
            event(.apply,   .governor, "x", 100),
            event(.release, .governor, "x", 9999),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(160))
        XCTAssertEqual(s.totalEpisodes, 1)
        XCTAssertEqual(s.totalThrottleSeconds, 60, accuracy: 0.001)
    }

    // MARK: - Multi-source / multi-app

    func testPerAppRollupSortedDescending() {
        let evs = [
            event(.apply,   .governor, "alpha",  0,  pid: 1),
            event(.release, .governor, "alpha", 30,  pid: 1),
            event(.apply,   .governor, "beta",   0,  pid: 2),
            event(.release, .governor, "beta", 100,  pid: 2),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.byApp.map(\.name), ["beta", "alpha"])
        XCTAssertEqual(s.byApp.first?.seconds ?? -1, 100, accuracy: 0.001)
    }

    func testPerSourceBreakdownCarriesAcrossApps() {
        let evs = [
            event(.apply,   .governor, "a",  0, pid: 1),
            event(.release, .governor, "a", 30, pid: 1),
            event(.apply,   .rule,     "b",  0, pid: 2),
            event(.release, .rule,     "b", 90, pid: 2),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.bySource[.governor] ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(s.bySource[.rule]     ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(s.bySource[.manual]   ?? -1, 0,  accuracy: 0.001)
    }

    func testSameAppDifferentSourcesAreDistinctEpisodes() {
        // Governor and rule both managing the same name must not fuse —
        // the (name, source) keying treats them as separate episodes.
        let evs = [
            event(.apply,   .governor, "x",  0),
            event(.release, .governor, "x", 30),
            event(.apply,   .rule,     "x", 40),
            event(.release, .rule,     "x", 70),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.totalEpisodes, 2)
        XCTAssertEqual(s.totalThrottleSeconds, 60, accuracy: 0.001)
    }

    // MARK: - Robustness

    func testOutOfOrderEventsHandled() {
        // Defensive sort inside aggregate: shuffled input shouldn't
        // change the result.
        let ordered = [
            event(.apply,   .governor, "x",  0),
            event(.release, .governor, "x", 30),
        ]
        let shuffled = ordered.reversed()
        let a = ThrottleSummary.aggregate(Array(ordered),  windowStart: t0, windowEnd: at(3600))
        let b = ThrottleSummary.aggregate(Array(shuffled), windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(a.totalThrottleSeconds, b.totalThrottleSeconds, accuracy: 0.001)
        XCTAssertEqual(a.totalEpisodes, b.totalEpisodes)
    }

    func testStrayReleaseWithoutApplyIgnored() {
        // Could happen if the file was truncated or events were
        // dropped — must not crash or produce negative totals.
        let evs = [
            event(.release, .governor, "x", 50),
        ]
        let s = ThrottleSummary.aggregate(evs, windowStart: t0, windowEnd: at(3600))
        XCTAssertEqual(s.totalEpisodes, 0)
        XCTAssertEqual(s.totalThrottleSeconds, 0)
    }

    // MARK: - Schema

    func testSourceDecodesUnknownAsOther() throws {
        // Future-proofing: if v0.13 adds `.policy`, an old binary
        // reading the new file should not fail the whole decode.
        let json = #"{"ts":"2024-01-01T00:00:00Z","kind":"apply","source":"policy","pid":1,"name":"x","duty":0.5}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ev = try decoder.decode(ThrottleEvent.self, from: Data(json.utf8))
        XCTAssertEqual(ev.source, .other)
    }
}
