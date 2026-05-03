import XCTest
@testable import AirAssist

/// Locks in the contract for the CPU activity rollup the dashboard
/// reads from. Pure function under test — no service instantiation
/// needed, just synthetic samples in, summary out.
final class CPUActivitySummaryTests: XCTestCase {

    // MARK: - Helpers

    private func sample(_ minutesAgo: TimeInterval,
                        cpu: Double,
                        bundle: String? = nil,
                        name: String = "test",
                        displayName: String = "Test",
                        from referenceDate: Date) -> CPUActivitySample {
        CPUActivitySample(
            timestamp: referenceDate.addingTimeInterval(-minutesAgo * 60),
            bundleID: bundle,
            name: name,
            displayName: displayName,
            cpuPercent: cpu
        )
    }

    private func makeSamples(
        groups: [(bundle: String?, name: String, count: Int, cpu: Double)],
        spanningMinutes: Int = 60,
        from referenceDate: Date
    ) -> [CPUActivitySample] {
        var out: [CPUActivitySample] = []
        for group in groups {
            for i in 0..<group.count {
                // Spread evenly through the window so the timestamp
                // pattern looks realistic.
                let minutes = Double(spanningMinutes) * Double(i) / Double(max(group.count, 1))
                out.append(sample(
                    minutes,
                    cpu: group.cpu,
                    bundle: group.bundle,
                    name: group.name,
                    displayName: group.name,
                    from: referenceDate
                ))
            }
        }
        return out
    }

    private func defaultWindow(from referenceDate: Date) -> (start: Date, end: Date) {
        (referenceDate.addingTimeInterval(-7 * 86400), referenceDate)
    }

    // MARK: - Empty / edge cases

    func testEmptySamplesIsEmptySummary() {
        let now = Date()
        let win = defaultWindow(from: now)
        let s = cpuActivitySummary(
            samples: [],
            windowStart: win.start,
            windowEnd: win.end,
            sampleIntervalSeconds: 60
        )
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertTrue(s.isEmpty)
    }

    func testSamplesOnlyOutsideWindowIsEmpty() {
        // 8 days ago — outside the 7-day default window.
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = [sample(8 * 24 * 60, cpu: 80, name: "old", from: now)]
        let s = cpuActivitySummary(
            samples: samples,
            windowStart: win.start,
            windowEnd: win.end,
            sampleIntervalSeconds: 60
        )
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertTrue(s.isEmpty,
                      "Out-of-window samples should make the summary read as empty")
    }

    func testSamplesInWindowButBelowThresholdGivesNoRows() {
        // Window has data, but everything is below threshold.
        // isEmpty should be FALSE (we did observe), rows empty.
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = makeSamples(
            groups: [(bundle: "com.test.idle", name: "idle", count: 30, cpu: 5)],
            from: now
        )
        let s = cpuActivitySummary(
            samples: samples,
            windowStart: win.start,
            windowEnd: win.end,
            sampleIntervalSeconds: 60,
            activityThreshold: 10
        )
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertFalse(s.isEmpty)
    }

    // MARK: - Grouping

    func testGroupsSamplesByBundleID() {
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = makeSamples(
            groups: [
                (bundle: "com.apple.Safari", name: "Safari", count: 10, cpu: 50),
                (bundle: "com.apple.Safari", name: "Safari Helper", count: 5, cpu: 30),
            ],
            from: now
        )
        let s = cpuActivitySummary(
            samples: samples,
            windowStart: win.start,
            windowEnd: win.end,
            sampleIntervalSeconds: 60,
            activityThreshold: 10
        )
        XCTAssertEqual(s.rows.count, 1)
        XCTAssertEqual(s.rows.first?.groupKey, "com.apple.Safari")
        XCTAssertEqual(s.rows.first?.sampleCount, 15)
    }

    func testGroupsSamplesWithoutBundleIDByName() {
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = makeSamples(
            groups: [
                (bundle: nil, name: "swift", count: 5, cpu: 80),
                (bundle: nil, name: "swift", count: 3, cpu: 40),
                (bundle: nil, name: "ld",    count: 2, cpu: 60),
            ],
            from: now
        )
        let s = cpuActivitySummary(
            samples: samples,
            windowStart: win.start,
            windowEnd: win.end,
            sampleIntervalSeconds: 60,
            activityThreshold: 10
        )
        XCTAssertEqual(s.rows.count, 2)
        let swiftRow = s.rows.first { $0.groupKey == "swift" }
        XCTAssertEqual(swiftRow?.sampleCount, 8)
    }

    // MARK: - Active seconds

    func testActiveSecondsScalesWithSampleInterval() {
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = makeSamples(
            groups: [(bundle: "com.test.app", name: "App", count: 10, cpu: 50)],
            from: now
        )

        let s60 = cpuActivitySummary(
            samples: samples, windowStart: win.start, windowEnd: win.end,
            sampleIntervalSeconds: 60
        )
        let s30 = cpuActivitySummary(
            samples: samples, windowStart: win.start, windowEnd: win.end,
            sampleIntervalSeconds: 30
        )

        // Same sample count, halved interval = halved active time.
        XCTAssertEqual(s60.rows.first?.activeSeconds, 600)
        XCTAssertEqual(s30.rows.first?.activeSeconds, 300)
    }

    // MARK: - Aggregate stats

    func testAvgAndPeakCpu() {
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = [
            sample(10, cpu: 30, bundle: "com.test.app", name: "App", displayName: "App", from: now),
            sample(20, cpu: 90, bundle: "com.test.app", name: "App", displayName: "App", from: now),
            sample(30, cpu: 60, bundle: "com.test.app", name: "App", displayName: "App", from: now),
        ]
        let s = cpuActivitySummary(
            samples: samples, windowStart: win.start, windowEnd: win.end,
            sampleIntervalSeconds: 60
        )
        XCTAssertEqual(s.rows.first?.avgCpuPercent, 60.0)   // (30 + 90 + 60) / 3
        XCTAssertEqual(s.rows.first?.peakCpuPercent, 90.0)
    }

    // MARK: - Display name

    func testDisplayNameFromMostRecentSample() {
        // App was renamed mid-window — use the latest display name.
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = [
            sample(60, cpu: 50, bundle: "com.test.app", name: "App", displayName: "App OldName", from: now),
            sample(30, cpu: 50, bundle: "com.test.app", name: "App", displayName: "App NewName", from: now),
        ]
        let s = cpuActivitySummary(
            samples: samples, windowStart: win.start, windowEnd: win.end,
            sampleIntervalSeconds: 60
        )
        XCTAssertEqual(s.rows.first?.displayName, "App NewName")
    }

    // MARK: - Sorting

    func testRowsSortedDescByActiveSeconds() {
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = makeSamples(
            groups: [
                (bundle: "com.a", name: "A", count: 5,  cpu: 40),  // 5 samples
                (bundle: "com.b", name: "B", count: 20, cpu: 40),  // 20 samples
                (bundle: "com.c", name: "C", count: 12, cpu: 40),  // 12 samples
            ],
            from: now
        )
        let s = cpuActivitySummary(
            samples: samples, windowStart: win.start, windowEnd: win.end,
            sampleIntervalSeconds: 60
        )
        XCTAssertEqual(s.rows.map(\.groupKey), ["com.b", "com.c", "com.a"])
    }

    func testTieBreakOnPeakWhenActiveSecondsEqual() {
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = [
            sample(10, cpu: 50,  bundle: "com.a", name: "A", displayName: "A", from: now),
            sample(10, cpu: 100, bundle: "com.b", name: "B", displayName: "B", from: now),
        ]
        let s = cpuActivitySummary(
            samples: samples, windowStart: win.start, windowEnd: win.end,
            sampleIntervalSeconds: 60
        )
        // Both have 1 sample = same active seconds. Tie breaks on
        // peak; b's 100% wins.
        XCTAssertEqual(s.rows.map(\.groupKey), ["com.b", "com.a"])
    }

    // MARK: - Top-N

    func testRespectsTopN() {
        let now = Date()
        let win = defaultWindow(from: now)
        let samples = makeSamples(
            groups: (1...20).map { (bundle: "com.app\($0)", name: "App\($0)", count: $0, cpu: 50) },
            from: now
        )
        let s = cpuActivitySummary(
            samples: samples, windowStart: win.start, windowEnd: win.end,
            sampleIntervalSeconds: 60,
            topN: 5
        )
        XCTAssertEqual(s.rows.count, 5)
        // Top 5 by sample count = apps 20, 19, 18, 17, 16
        XCTAssertEqual(s.rows.map(\.groupKey),
                       ["com.app20", "com.app19", "com.app18", "com.app17", "com.app16"])
    }
}
