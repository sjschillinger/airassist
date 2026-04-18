import Foundation
import Darwin

/// Throttles running processes via SIGSTOP/SIGCONT duty cycling — AppTamer's
/// public-API approach. For each throttled PID, a background task cycles:
///
///     SIGSTOP for (1-duty)·period   → process is paused
///     SIGCONT for  duty   ·period   → process runs
///
/// A `duty` of 1.0 means "no throttle" (task is not started). A duty of 0.05
/// means the process runs only 5% of wall time. Period is ~100ms which is a
/// good balance between responsiveness and scheduler overhead.
///
/// Safety:
///   * Never throttles a PID whose name is in `ProcessInspector.excludedNames`.
///   * Never throttles PIDs not owned by the current UID.
///   * On process death (`kill` returns `ESRCH`), the cycler exits cleanly.
///   * `releaseAll()` must be called on app teardown to SIGCONT anything we
///     left paused — otherwise a stopped process survives our exit.
@MainActor
final class ProcessThrottler {

    /// Cycler period. 100ms ≈ 10 Hz — snappy enough to feel live but cheap.
    static let cyclePeriodMs: Int = 100
    /// Minimum / maximum duty accepted. 1.0 means "ignore / untrottle".
    static let minDuty: Double = 0.05
    static let maxDuty: Double = 1.0

    /// Per-PID state. `task` is the cycler; `duty` is its current target.
    private struct Entry {
        var duty: Double
        var name: String
        var task: Task<Void, Never>
    }

    private var active: [pid_t: Entry] = [:]
    private let currentUID: uid_t = getuid()

    // MARK: - Public API

    /// Apply a duty to a pid. If duty ≥ 1.0 the pid is released. Idempotent:
    /// calling with the same duty does nothing; calling with a new duty
    /// updates the live target.
    func setDuty(_ rawDuty: Double, for pid: pid_t, name: String) {
        guard pid > 0 else { return }
        // Safety: never throttle excluded system processes.
        if ProcessInspector.excludedNames.contains(name) {
            release(pid: pid)
            return
        }
        // Safety: never touch processes we don't own.
        var uid: uid_t = 0
        if !ownedByCurrentUser(pid: pid, uidOut: &uid) {
            release(pid: pid)
            return
        }

        let duty = clamp(rawDuty, lo: Self.minDuty, hi: Self.maxDuty)
        if duty >= Self.maxDuty {
            release(pid: pid)
            return
        }

        if var existing = active[pid] {
            // Just update the target. The live task reads the latest duty
            // out of `active` each cycle.
            existing.duty = duty
            active[pid] = existing
            return
        }

        // Spawn a new cycler.
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runCycle(pid: pid)
        }
        active[pid] = Entry(duty: duty, name: name, task: task)
    }

    /// Release a single pid — SIGCONT and cancel its cycler.
    func release(pid: pid_t) {
        guard let entry = active.removeValue(forKey: pid) else { return }
        entry.task.cancel()
        _ = kill(pid, SIGCONT)
    }

    /// Release everything. Call on teardown / when the rule engine disables.
    func releaseAll() {
        for (pid, entry) in active {
            entry.task.cancel()
            _ = kill(pid, SIGCONT)
            _ = pid // silence unused warning in minimal builds
        }
        active.removeAll()
    }

    /// PIDs currently under active throttling, with their current duty.
    var throttledPIDs: [(pid: pid_t, duty: Double, name: String)] {
        active.map { (pid: $0.key, duty: $0.value.duty, name: $0.value.name) }
    }

    /// Is this pid currently throttled?
    func isThrottled(pid: pid_t) -> Bool { active[pid] != nil }

    // MARK: - Cycler

    /// Main loop for a single pid. Reads the latest duty each iteration so
    /// updates take effect within one cycle.
    private func runCycle(pid: pid_t) async {
        let periodNs: UInt64 = UInt64(Self.cyclePeriodMs) * 1_000_000

        while !Task.isCancelled {
            // Snapshot current duty (may have been updated by setDuty).
            let duty: Double = await MainActor.run {
                active[pid]?.duty ?? Self.maxDuty
            }
            if duty >= Self.maxDuty { return }

            let runNs  = UInt64(Double(periodNs) * duty)
            let stopNs = periodNs &- runNs

            // RUN phase: ensure SIGCONT, sleep run-slice.
            if !signal(SIGCONT, to: pid) { return }
            if runNs > 0 {
                try? await Task.sleep(nanoseconds: runNs)
            }
            if Task.isCancelled { _ = kill(pid, SIGCONT); return }

            // STOP phase: SIGSTOP, sleep stop-slice.
            if stopNs > 0 {
                if !signal(SIGSTOP, to: pid) { return }
                try? await Task.sleep(nanoseconds: stopNs)
            }
        }
        // On cancellation, always resume the process.
        _ = kill(pid, SIGCONT)
    }

    /// Sends `sig` to `pid`. Returns false if the process is gone (ESRCH) or
    /// another unrecoverable error — caller should stop the cycler.
    private func signal(_ sig: Int32, to pid: pid_t) -> Bool {
        let r = kill(pid, sig)
        if r == 0 { return true }
        if errno == ESRCH { return false } // process died; unwind.
        // EPERM etc. — can't control it; give up.
        return false
    }

    private func ownedByCurrentUser(pid: pid_t, uidOut: inout uid_t) -> Bool {
        var bsd = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let ret = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
        }
        guard ret == Int32(size) else { return false }
        uidOut = bsd.pbi_uid
        return bsd.pbi_uid == currentUID
    }

    private func clamp(_ x: Double, lo: Double, hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}
