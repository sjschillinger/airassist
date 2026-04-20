import XCTest
import Darwin
@testable import AirAssist

/// The watchdog is the last line of defense against a main-actor hang that
/// leaves a process SIGSTOP'd. These tests verify the two invariants it
/// has to hold:
///
///   1. If `noteStopped(pid:)` is called and no `noteContinued(pid:)`
///      follows within `watchdogMaxPauseMs`, the watchdog eventually
///      SIGCONTs the pid on its own.
///   2. If `noteContinued(pid:)` is called in time, the watchdog stays
///      silent (does not force-SIGCONT a healthy pid out from under a
///      working cycler).
///
/// The watchdog lives off the main actor (detached `.utility` Task), so
/// these tests must use real time, not simulated clocks. Budget:
///   - `watchdogMaxPauseMs` is 1500 ms by default.
///   - `watchdogTickMs` is 250 ms.
///   - Worst case from `noteStopped` to observed force-SIGCONT is
///     1500 + 250 + scheduling jitter ≈ 1.8–2.0 s.
/// So the "should fire" test budgets 3.0 s, the "should stay silent" test
/// budgets 2.5 s and expects *no* resume to occur.
@MainActor
final class WatchdogForceSIGCONTTests: XCTestCase {

    private var spawnedPIDs: [pid_t] = []
    private var safety: SafetyCoordinator?

    override func tearDown() async throws {
        safety?.stopWatchdog()
        safety = nil
        // Always SIGKILL any child we spawned. SIGCONT first so SIGKILL
        // can actually deliver to a stopped process.
        for pid in spawnedPIDs {
            _ = kill(pid, SIGCONT)
            _ = kill(pid, SIGKILL)
        }
        spawnedPIDs.removeAll()
    }

    private func spawnSleep() throws -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        let pid = p.processIdentifier
        XCTAssertGreaterThan(pid, 1)
        spawnedPIDs.append(pid)
        return pid
    }

    private func bsdStatus(of pid: pid_t) -> Int32? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let ret = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
        }
        guard ret == Int32(size) else { return nil }
        return Int32(info.pbi_status)
    }

    /// Poll for the pid to be in a non-SSTOP state (runnable/sleeping).
    private func awaitResumed(pid: pid_t, within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = bsdStatus(of: pid), s != 4 { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: - Tests

    /// Simulate a cycler that SIGSTOP'd a pid and then stalled (never
    /// called `noteContinued`). The watchdog should detect the overdue
    /// stop timestamp and force-SIGCONT the pid on its own.
    func testWatchdogForcesSIGCONTOnStalledStop() async throws {
        let pid = try spawnSleep()
        let safety = SafetyCoordinator()
        self.safety = safety

        // Simulate the cycler's SIGSTOP, then inform the watchdog but
        // NEVER send the follow-up noteContinued. This is the main-actor-
        // hang failure mode: the in-memory bookkeeping records a stop, but
        // the cycler is now frozen and can't issue the paired SIGCONT.
        XCTAssertEqual(kill(pid, SIGSTOP), 0,
                       "SIGSTOP to our own child must succeed")
        safety.noteStopped(pid: pid)
        safety.startWatchdog()

        // watchdogMaxPauseMs (1500) + one watchdogTickMs (250) + jitter.
        let resumed = await awaitResumed(pid: pid, within: 3.0)
        XCTAssertTrue(resumed,
                      "watchdog did not force-SIGCONT a stalled stop within 3s — " +
                      "pid \(pid) still in SSTOP")
    }

    /// If `noteContinued` arrives in time, the watchdog must stay
    /// silent. Otherwise any healthy cycler's work would be undone by a
    /// spurious resume.
    func testWatchdogStaysSilentWhenContinuedInTime() async throws {
        let pid = try spawnSleep()
        let safety = SafetyCoordinator()
        self.safety = safety

        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        safety.noteStopped(pid: pid)
        safety.startWatchdog()

        // Follow up with noteContinued well within the 1500ms budget.
        try await Task.sleep(nanoseconds: 200_000_000)   // 200ms
        // Resume for real too — we don't want to leave the child stopped.
        XCTAssertEqual(kill(pid, SIGCONT), 0)
        safety.noteContinued(pid: pid)

        // Now freeze the child again, but DON'T tell the watchdog — from
        // its perspective the last event was noteContinued, so it should
        // leave this new SIGSTOP alone. If the watchdog incorrectly tracked
        // the first note forever, it'd force-resume here.
        XCTAssertEqual(kill(pid, SIGSTOP), 0)

        // Wait longer than watchdogMaxPauseMs + tick, then verify the
        // process is STILL stopped — proof the watchdog didn't spuriously
        // intervene.
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s
        let status = bsdStatus(of: pid)
        XCTAssertEqual(status, 4 /* SSTOP */,
                       "watchdog spuriously resumed a pid it had no record of stopping")

        // Clean up so tearDown's SIGKILL can deliver.
        _ = kill(pid, SIGCONT)
    }

    /// After `resetStopTimestamps()` (called on releaseAll), the watchdog
    /// must drop all tracking. Without this, a releaseAll followed by a
    /// new unrelated SIGSTOP on a recycled pid could be spuriously
    /// force-continued.
    func testResetStopTimestampsClearsWatchdog() async throws {
        let pid = try spawnSleep()
        let safety = SafetyCoordinator()
        self.safety = safety

        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        safety.noteStopped(pid: pid)
        safety.startWatchdog()

        // Immediately reset — simulates releaseAll().
        safety.resetStopTimestamps()

        // The stop timestamp is gone; the watchdog should not observe the
        // pid as overdue. Wait through the max-pause window + a tick and
        // verify the pid is still in SSTOP (watchdog never fired).
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(bsdStatus(of: pid), 4 /* SSTOP */,
                       "watchdog fired on a pid whose timestamp had been reset")

        _ = kill(pid, SIGCONT)
    }
}
