import XCTest
import Darwin
@testable import AirAssist

/// End-to-end signal test — spawns a real child process, asks
/// `ProcessThrottler` to duty-cycle it, and verifies the kernel actually
/// sees SIGSTOP/SIGCONT land. Complements the algorithmic tests in
/// `ProcessThrottlerArbitrationTests` which can't SIGSTOP anything because
/// the ancestor-protection layer refuses to touch the test process's own
/// PID (and every child it spawns is protected for the same reason).
///
/// Here we explicitly disable `protectAncestors` on a fresh throttler
/// instance, spawn `/bin/sleep 60` as the target, and check the child's
/// BSD process state via `proc_pidinfo(PROC_PIDTBSDINFO)`. SIGSTOP puts
/// the process in SSTOP (4); SIGCONT returns it to SSLEEP (3) or SRUN (2).
@MainActor
final class ProcessThrottlerSignalTests: XCTestCase {

    private var spawnedPIDs: [pid_t] = []

    override func tearDown() async throws {
        // Always SIGKILL any child we spawned, even if the test body bailed
        // early — we must never leak a SIGSTOP'd sleep that survives the
        // test process's exit.
        for pid in spawnedPIDs {
            _ = kill(pid, SIGCONT)  // unfreeze first so SIGKILL can deliver
            _ = kill(pid, SIGKILL)
        }
        spawnedPIDs.removeAll()
    }

    /// Spawn `/bin/sleep 60` and return its pid. Registers the pid for
    /// cleanup in tearDown.
    private func spawnSleep() throws -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        let pid = p.processIdentifier
        XCTAssertGreaterThan(pid, 1, "spawned pid should be a real user pid")
        spawnedPIDs.append(pid)
        return pid
    }

    /// Read BSD process state via libproc. Returns nil if the pid is gone.
    /// Status codes (from `sys/proc.h`): 1=SIDL, 2=SRUN, 3=SSLEEP,
    /// 4=SSTOP, 5=SZOMB.
    private func bsdStatus(of pid: pid_t) -> Int32? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let ret = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
        }
        guard ret == Int32(size) else { return nil }
        return Int32(info.pbi_status)
    }

    /// Poll for the child to be observed in SSTOP state within a deadline.
    /// Returns true if we ever saw the process stopped.
    private func awaitStopped(pid: pid_t, within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bsdStatus(of: pid) == 4 /* SSTOP */ { return true }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
        return false
    }

    /// Poll for the child to be observed NOT in SSTOP (SIGCONT landed).
    private func awaitResumed(pid: pid_t, within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = bsdStatus(of: pid), s != 4 { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    // MARK: - Tests

    /// Asking the throttler to cap a spawned child at a low duty should,
    /// within a cycle or two, produce an observable SIGSTOP in the
    /// kernel's view of the process. This is the round-trip we rely on
    /// to claim the feature works at all.
    func testSetDutyActuallySIGSTOPsTarget() async throws {
        let pid = try spawnSleep()
        let throttler = ProcessThrottler()
        throttler.protectAncestors = false   // child IS our descendant
        defer { throttler.releaseAll() }

        throttler.setDuty(0.1, for: pid, name: "sleep", source: .rule)
        XCTAssertTrue(throttler.isThrottled(pid: pid),
                      "throttler should track pid immediately after setDuty")

        // 500 ms is 5 cycles at the default 100 ms period — more than
        // enough to catch a SIGSTOP slice at 10% duty.
        let sawStop = await awaitStopped(pid: pid, within: 0.5)
        XCTAssertTrue(sawStop,
                      "kernel never observed SIGSTOP on pid \(pid) within 500ms — " +
                      "cycler did not deliver the signal")
    }

    /// After `release(pid:)`, the child must be left in a runnable state.
    /// This is the contract the SIGCONT-retry path exists to honor: a
    /// user-facing throttle release must never leave a process frozen.
    func testReleaseLeavesChildRunning() async throws {
        let pid = try spawnSleep()
        let throttler = ProcessThrottler()
        throttler.protectAncestors = false

        throttler.setDuty(0.1, for: pid, name: "sleep", source: .rule)
        _ = await awaitStopped(pid: pid, within: 0.5)
        throttler.release(pid: pid)

        // Give the cycler a moment to exit and the final SIGCONT to land.
        let resumed = await awaitResumed(pid: pid, within: 0.5)
        XCTAssertTrue(resumed,
                      "release(pid:) did not resume the child — it's still in SSTOP")
        XCTAssertFalse(throttler.isThrottled(pid: pid),
                       "throttler should drop the pid on release()")
    }

    /// `releaseAll()` must do the same for every tracked pid, not just the
    /// head of the dictionary. Regression guard against "we iterated and
    /// mutated at the same time" bugs.
    func testReleaseAllResumesEveryChild() async throws {
        let pidA = try spawnSleep()
        let pidB = try spawnSleep()
        let throttler = ProcessThrottler()
        throttler.protectAncestors = false

        throttler.setDuty(0.1, for: pidA, name: "sleep", source: .rule)
        throttler.setDuty(0.1, for: pidB, name: "sleep", source: .rule)
        _ = await awaitStopped(pid: pidA, within: 0.5)
        _ = await awaitStopped(pid: pidB, within: 0.5)

        throttler.releaseAll()

        let resumedA = await awaitResumed(pid: pidA, within: 0.5)
        let resumedB = await awaitResumed(pid: pidB, within: 0.5)
        XCTAssertTrue(resumedA && resumedB,
                      "releaseAll did not resume both children (A=\(resumedA) B=\(resumedB))")
    }

    /// When the target process exits on its own, the throttler must
    /// drop its bookkeeping — otherwise the next setDuty collision or
    /// PID-reuse can send SIGSTOP to an unrelated process. The kqueue
    /// exit watcher is what makes this prompt (<50 ms typical).
    func testExitWatcherDropsEntryOnChildDeath() async throws {
        let pid = try spawnSleep()
        let throttler = ProcessThrottler()
        throttler.protectAncestors = false
        defer { throttler.releaseAll() }

        throttler.setDuty(0.3, for: pid, name: "sleep", source: .rule)
        XCTAssertTrue(throttler.isThrottled(pid: pid))

        // Kill the child ourselves. SIGKILL is unmaskable so this is immediate.
        _ = kill(pid, SIGCONT)  // must resume before SIGKILL on a stopped pid
        _ = kill(pid, SIGKILL)

        // Give kqueue + the MainActor hop in installExitWatcher's handler
        // a reasonable window. 500 ms is an order of magnitude over the
        // ~10 ms typical exit-to-handler latency.
        let deadline = Date().addingTimeInterval(0.5)
        var dropped = false
        while Date() < deadline {
            if !throttler.isThrottled(pid: pid) { dropped = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(dropped,
                      "exit watcher did not drop pid \(pid) within 500ms of SIGKILL")
    }
}
