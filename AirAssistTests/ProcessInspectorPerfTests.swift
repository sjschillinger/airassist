import XCTest
@testable import AirAssist

/// Perf envelope for `ProcessInspector.snapshot()` (#50).
///
/// The control loop runs at 1 Hz on the main actor. If a snapshot takes
/// more than ~100ms under load, the main actor stalls and UI gets janky.
/// This test measures the cost against whatever's live on the test host
/// (typically 400-800 PIDs on a dev Mac) plus 200 noop child processes
/// spawned for the duration of the test to stress the enumerator.
///
/// We don't assert a hard ms ceiling — Xcode's `measure` baseline machinery
/// is the right place for that (set a baseline in the Report Navigator,
/// regressions fail CI). What we do assert is that the scan completes
/// without errors and returns a non-empty result, which is a smoke test
/// for libproc-vs-hardened-runtime interactions that might regress across
/// macOS releases.
@MainActor
final class ProcessInspectorPerfTests: XCTestCase {

    /// Number of `sleep` child processes to spawn for the duration of
    /// each test. 200 is enough to noticeably lengthen proc_listpids
    /// without risking the test machine's process table (the per-user
    /// rlimit default is 2048 on macOS).
    private static let childrenToSpawn = 200

    private var children: [Process] = []

    override func setUp() async throws {
        // Spawn children once per test. Each sleeps 60s and will be
        // torn down in tearDown (or when its Process deinits, whichever
        // fires first).
        children.reserveCapacity(Self.childrenToSpawn)
        for _ in 0..<Self.childrenToSpawn {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["60"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                children.append(p)
            } catch {
                // Hit some system limit — that's fine, partial fleet still
                // exercises the code path.
                break
            }
        }
        // Brief settle so the new PIDs are in libproc's tables.
        try await Task.sleep(for: .milliseconds(100))
    }

    override func tearDown() async throws {
        for p in children where p.isRunning {
            p.terminate()
        }
        children.removeAll()
    }

    func test_snapshotCompletesUnderLoad() {
        let inspector = ProcessInspector()
        let snap = inspector.snapshot()
        XCTAssertFalse(snap.isEmpty, "snapshot returned zero processes — libproc broken?")
        // Sanity check: at least some of our sleep children should be in
        // the result. We don't require all of them because the test harness
        // itself might be sampled before every child is fully scheduled.
        let sleepCount = snap.filter { $0.name == "sleep" }.count
        XCTAssertGreaterThanOrEqual(sleepCount, Self.childrenToSpawn / 4,
                                    "Expected many 'sleep' procs, saw \(sleepCount)")
    }

    /// Xcode perf test. Set a baseline in the Report Navigator the first
    /// time this runs; subsequent regressions will fail.
    func test_snapshotPerformance() {
        let inspector = ProcessInspector()
        measure {
            for _ in 0..<10 {
                _ = inspector.snapshot()
            }
        }
    }

    /// Secondary: the topUserProcessesByCPU path is what the UI actually
    /// hits, and it runs snapshot + sort + filter. Measure end-to-end.
    func test_topUserProcessesPerformance() {
        let inspector = ProcessInspector()
        // Prime the lastSnapshot map so CPU% is computed against a delta.
        _ = inspector.snapshot()
        measure {
            for _ in 0..<10 {
                _ = inspector.topUserProcessesByCPU(limit: 10)
            }
        }
    }
}
