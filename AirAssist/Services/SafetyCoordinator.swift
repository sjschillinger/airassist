import Foundation
import Darwin
import os

/// Safety layer for the SIGSTOP-based throttler. Three jobs:
///
/// 1. **Dead-man's-switch file.** Every time the set of in-flight (stopped)
///    PIDs changes, write it to disk. On next launch, unconditionally SIGCONT
///    every PID in that file before doing anything else. Covers the case
///    where the app crashed, was SIGKILLed, or the machine panicked while a
///    process was paused.
///
/// 2. **Signal handlers.** Install handlers for SIGTERM/SIGINT/SIGHUP/SIGQUIT
///    that synchronously SIGCONT every in-flight PID, then re-raise with the
///    default handler so the process exits normally. `kill(2)` is
///    async-signal-safe; the inflight list lives in a fixed-capacity C buffer
///    specifically so the handler can read it without locking or allocation.
///
/// 3. **Watchdog.** ~4Hz **off-main-actor** task; if any PID has been
///    continuously SIGSTOP'd for longer than `maxPauseMs` (default 1.5s),
///    force SIGCONT. Runs on a detached task with its own unfair-lock-guarded
///    timestamp store so a stalled main actor (the exact failure mode we're
///    protecting against) cannot disable the safety net. Protects against a
///    stuck cycler loop, runaway duty-cycle error, or UI hang that's keeping
///    the main actor from ticking.
///
/// Own-process-tree protection lives inline in `ProcessThrottler.setDuty`
/// via `SafetyCoordinator.isAncestorOrSelf(pid:)`.
@MainActor
final class SafetyCoordinator {

    // MARK: - Configuration

    /// Maximum continuous SIGSTOP duration before the watchdog intervenes.
    /// Set to 1.5s: with a 100ms cycle period the worst legitimate stop is
    /// ~95ms (duty 0.05 × 100ms), so 1500ms gives ~15× headroom. A tighter
    /// bound like 500ms can false-fire when the main actor is loaded
    /// (Xcode Instruments attached, large sensor poll, etc.) and the
    /// cycler's `await MainActor.run` hops get delayed — forcing SIGCONT
    /// then wastes the cycle's stop phase.
    nonisolated static let watchdogMaxPauseMs: Int = 1_500
    /// Watchdog tick period.
    nonisolated static let watchdogTickMs: Int = 250

    // Nonisolated so the detached watchdog task can call logger.error without
    // a main-actor hop — the hop would defeat the purpose of this being
    // off-main. Logger itself is Sendable.
    nonisolated private static let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                                   category: "Safety")

    // MARK: - Dead-man's-switch file

    private static let appSupportDirName = "AirAssist"
    private static let inflightFileName  = "inflight.json"

    /// Absolute path to the dead-man's-switch file.
    static var inflightFileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(appSupportDirName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(inflightFileName)
    }

    private struct InflightRecord: Codable {
        var pids: [Int32]
        var writtenAt: Date
    }

    /// Called on every throttler mutation. Rewrites the inflight file with
    /// `fsync` semantics before updating the in-memory signal-handler buffer
    /// so a crash between the two leaves behind a *safe* state: the file on
    /// disk is already the authoritative record.
    ///
    /// Ordering is critical: we persist INTENT first, then update the runtime
    /// structures. If we crash mid-write, `recoverOnLaunch` sees either the
    /// old file (we un-freeze yesterday's pids — harmless: they've been gone
    /// since reboot) or the new file (we un-freeze the pids we were about to
    /// SIGSTOP — also harmless, they're in a run-slice anyway).
    static func writeInflight(pids: [pid_t]) {
        let url = inflightFileURL
        if pids.isEmpty {
            try? FileManager.default.removeItem(at: url)
            updateSignalHandlerPIDs([])
            return
        }
        let rec = InflightRecord(pids: pids.map { Int32($0) }, writtenAt: Date())
        do {
            let data = try JSONEncoder().encode(rec)
            if !writeAtomicWithFsync(data: data, to: url) {
                // Last-resort fallback. Logged inside the helper.
                try? data.write(to: url, options: .atomic)
            }
        } catch {
            Self.logger.error("encode inflight record failed: \(String(describing: error), privacy: .public)")
        }
        updateSignalHandlerPIDs(pids)
    }

    /// Atomic write + fsync of the dead-man's-switch inflight file.
    ///
    /// `Data.write(to:options:.atomic)` uses rename-atomic which survives a
    /// crash between tmp-write and rename, but the tmp-write itself is not
    /// guaranteed flushed to disk before rename — a kernel panic within
    /// milliseconds of rename can leave the rename on disk but the file
    /// contents empty. `fsync` (on the file *and* parent directory) closes
    /// that window.
    ///
    /// Returns `true` only if the data is durably persisted at `url`.
    /// Callers can retry / fall back when this returns `false`.
    ///
    /// Audit Tier 0 item 4 (Codex PARTIAL): the previous version silently
    /// ignored short writes, fsync return, and rename return. The durability
    /// comments above were stronger than the code — this version checks
    /// every step, retries partial writes, fsyncs the parent dir, and logs
    /// each distinct failure class once.
    @discardableResult
    private static func writeAtomicWithFsync(data: Data, to url: URL) -> Bool {
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        let path = tmp.path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            logFsyncFailure("open(\(path))", err: errno)
            return false
        }

        // 1. Write the full payload, looping over short / EINTR returns.
        let writeOK = data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            var remaining = buf.count
            var ptr = base.assumingMemoryBound(to: UInt8.self)
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n > 0 {
                    remaining -= n
                    ptr = ptr.advanced(by: n)
                    continue
                }
                if n == -1 && errno == EINTR { continue }
                logFsyncFailure("write", err: n == -1 ? errno : 0)
                return false
            }
            return true
        }
        guard writeOK else {
            close(fd)
            unlink(path)
            return false
        }

        // 2. fsync the file before rename so the rename can't outrun the data.
        if fsync(fd) != 0 {
            logFsyncFailure("fsync(file)", err: errno)
            close(fd)
            unlink(path)
            return false
        }
        close(fd)

        // 3. Rename is atomic on APFS / HFS+.
        if rename(path, url.path) != 0 {
            logFsyncFailure("rename", err: errno)
            unlink(path)
            return false
        }

        // 4. fsync the parent directory so the rename itself is durable
        //    across a crash. Without this, on some filesystems the directory
        //    entry can be lost even though the inode survives. Failure here
        //    is logged but not treated as fatal — the data IS on disk.
        let parentPath = url.deletingLastPathComponent().path
        let dirFd = open(parentPath, O_RDONLY)
        if dirFd >= 0 {
            if fsync(dirFd) != 0 {
                logFsyncFailure("fsync(parent)", err: errno)
            }
            close(dirFd)
        } else {
            logFsyncFailure("open(parent)", err: errno)
        }
        return true
    }

    /// One log line per distinct (op, errno) pair. A permanently-full disk
    /// hits this ~once per safety event otherwise; this caps the noise.
    private static let loggedFsyncFailures = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static func logFsyncFailure(_ op: String, err: Int32) {
        let key = "\(op):\(err)"
        let firstTime = loggedFsyncFailures.withLock { $0.insert(key).inserted }
        guard firstTime else { return }
        if err == 0 {
            logger.error("inflight-write \(op, privacy: .public) failed (no errno set)")
        } else {
            logger.error("inflight-write \(op, privacy: .public) failed: errno=\(err, privacy: .public) (\(String(cString: strerror(err)), privacy: .public))")
        }
    }

    /// Call very early in app launch (before starting any throttler). Reads
    /// the inflight file left by a previous session, SIGCONTs every PID,
    /// then deletes the file.
    ///
    /// Hardened against corruption (empty file, truncated, wrong schema,
    /// non-JSON garbage, wrong types for pids, absurd pid values). A junk
    /// file must not crash the app or prevent launch — the file is removed
    /// in every path so a bad file self-heals on the next boot.
    static func recoverOnLaunch() {
        let url = inflightFileURL
        defer { try? FileManager.default.removeItem(at: url) }

        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let rec = try? JSONDecoder().decode(InflightRecord.self, from: data)
        else {
            return
        }
        var recovered = 0
        for raw in rec.pids {
            // Reject absurd / malicious pid values before handing them to kill(2).
            // pid_t is 32-bit signed; legitimate pids are 1…~99999 on Darwin.
            guard raw > 1, raw < 1_000_000 else { continue }
            let pid = pid_t(raw)
            // kill() returns ESRCH if pid is gone — fine, move on. Don't
            // race-check: by the time recoverOnLaunch runs, pid reuse would
            // require something to have spawned *and* matched this pid in
            // the microseconds since reboot, which is a corner of a corner.
            if kill(pid, SIGCONT) == 0 { recovered += 1 }
        }
        if recovered > 0 || !rec.pids.isEmpty {
            logger.info("recoverOnLaunch: released \(recovered) of \(rec.pids.count) pids from inflight file")
        }
    }

    // MARK: - Signal handlers

    /// Install SIGTERM/SIGINT/SIGHUP/SIGQUIT handlers that release all
    /// in-flight PIDs before letting the default handler exit the process.
    static func installSignalHandlers() {
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]
        for s in signals {
            var act = sigaction()
            act.__sigaction_u = __sigaction_u(__sa_handler: airAssistSignalHandler)
            sigemptyset(&act.sa_mask)
            act.sa_flags = 0
            sigaction(s, &act, nil)
        }
    }

    // MARK: - Watchdog (runs OFF main actor)

    private var watchdogTask: Task<Void, Never>?
    /// Lock-protected stop-timestamp store. Lives outside the main actor so
    /// the watchdog task can read it even when the main actor is hung — the
    /// watchdog is the last line of defense against a main-actor hang that
    /// leaves a process SIGSTOP'd, so it cannot itself depend on the main
    /// actor being responsive.
    nonisolated private let watchdogState = OSAllocatedUnfairLock<WatchdogState>(initialState: .init())

    private struct WatchdogState {
        var stopTimestamps: [pid_t: Date] = [:]
    }

    /// Report that the cycler just issued SIGSTOP for a pid. Nonisolated so
    /// it can be called from the cycler's detached task directly (no main-actor
    /// hop required), keeping the safety net honest when main is slow.
    nonisolated func noteStopped(pid: pid_t) {
        watchdogState.withLock { $0.stopTimestamps[pid] = Date() }
    }

    /// Report that the cycler just issued SIGCONT for a pid.
    nonisolated func noteContinued(pid: pid_t) {
        watchdogState.withLock { state in
            state.stopTimestamps.removeValue(forKey: pid)
            // ^ returns the removed Date, but we don't care about it.
            // Explicitly discard so the lock's return value is Void.
            return
        }
    }

    /// Clear all stop timestamps (called on releaseAll).
    nonisolated func resetStopTimestamps() {
        watchdogState.withLock { $0.stopTimestamps.removeAll() }
    }

    /// Called by `ProcessThrottler` after any mutation to the active set.
    /// Updates both the on-disk dead-man's-switch file and the in-memory
    /// signal-handler PID array.
    func noteInflightChange(pids: [pid_t]) {
        Self.writeInflight(pids: pids)
    }

    func startWatchdog() {
        watchdogTask?.cancel()
        let state = watchdogState
        let tickMs = Self.watchdogTickMs
        let limit = TimeInterval(Self.watchdogMaxPauseMs) / 1000.0
        // Detached, .utility QoS: does not inherit the main actor, does not
        // yield cooperatively to main-actor-blocked code. The whole point of
        // this task is to fire when main is stuck.
        watchdogTask = Task.detached(priority: .utility) {
            let period: UInt64 = UInt64(tickMs) * 1_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: period)
                let now = Date()
                let stuck: [pid_t] = state.withLock { inner in
                    let overdue = inner.stopTimestamps
                        .filter { now.timeIntervalSince($0.value) > limit }
                        .map(\.key)
                    for pid in overdue { inner.stopTimestamps.removeValue(forKey: pid) }
                    return overdue
                }
                for pid in stuck {
                    // Force-continue and forget. Cycler will re-stop it on
                    // the next iteration if still applicable; meanwhile the
                    // process is not locked up. kill() is async-signal-safe
                    // and does not require main-actor context.
                    _ = kill(pid, SIGCONT)
                    Self.logger.error("watchdog force-SIGCONT pid=\(pid) (exceeded \(Self.watchdogMaxPauseMs)ms stop budget)")
                }
            }
        }
    }

    func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Own-process-tree protection

    /// True if `pid` is this process, any ancestor, or (defensively) pid 1.
    /// Prevents the rare footgun of throttling our own parent shell or the
    /// app itself.
    static func isAncestorOrSelf(pid: pid_t) -> Bool {
        if pid <= 1 { return true }
        let selfPID = getpid()
        if pid == selfPID { return true }

        // Walk parent chain up to init. Cap iterations to avoid any weird cycle.
        var cursor: pid_t = pid
        for _ in 0..<64 {
            var bsd = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let ret = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
                proc_pidinfo(cursor, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
            }
            guard ret == Int32(size) else { return false }
            let parent = pid_t(bsd.pbi_ppid)
            if parent == selfPID { return true }
            if parent <= 1 { return false }
            cursor = parent
        }
        return false
    }
}

// MARK: - C signal plumbing
//
// Signal handlers cannot call Swift methods or allocate. We keep the list of
// in-flight PIDs in a fixed-capacity heap buffer (allocated once at first
// use, never reallocated) and a count. Writes are ordered so the handler
// sees either the old or the new state but never a torn one:
//
//   * Shrinking (n < old): write count FIRST, then write new pids. Handler
//     reads smaller count and iterates only slots we haven't touched yet.
//   * Growing (n >= old):  write new pids FIRST, then write count. Handler
//     either sees old count (skips new entries — safe) or new count (the
//     new slots are already populated — also safe).
//
// The previous implementation used a Swift `Array<pid_t>` global, which can
// be reallocated under ARC/COW; a signal firing mid-reallocation could read
// a dangling buffer. A fixed heap buffer with direct pointer stores closes
// that class of bug entirely.

private let kInflightCapacity: Int = 256
nonisolated(unsafe) private let gInflightPIDs: UnsafeMutablePointer<pid_t> = {
    let p = UnsafeMutablePointer<pid_t>.allocate(capacity: kInflightCapacity)
    p.initialize(repeating: 0, count: kInflightCapacity)
    return p
}()
nonisolated(unsafe) private var gInflightCount: Int32 = 0

/// Update the signal-handler-visible PID list. Called from `writeInflight`
/// on the main actor; the signal handler reads without locking.
fileprivate func updateSignalHandlerPIDs(_ pids: [pid_t]) {
    let n = min(pids.count, kInflightCapacity)
    let old = Int(gInflightCount)
    if n < old {
        // Shrink: publish smaller count first, then rewrite slots. The
        // handler won't read past the new count so stale data in slots
        // [n..<old] is invisible.
        gInflightCount = Int32(n)
        for i in 0..<n { gInflightPIDs[i] = pids[i] }
    } else {
        // Grow / equal: fill slots first, publish count last. The handler
        // sees either the old count (fewer pids, all still valid) or the
        // new count (all new pids already in place).
        for i in 0..<n { gInflightPIDs[i] = pids[i] }
        gInflightCount = Int32(n)
    }
}

/// C-compatible signal handler. Releases every pid then re-raises with
/// default disposition so the process exits.
///
/// All calls here must be async-signal-safe — `kill`, `sigaction`, and
/// `raise` qualify per POSIX. Do not add stdio / malloc / Swift method
/// calls.
@_cdecl("airAssistSignalHandler")
fileprivate func airAssistSignalHandler(_ sig: Int32) {
    // Snapshot count once — if a concurrent writer bumps it after we read,
    // we just miss the newly-added pid (which is also in-flight in the
    // writer's Task.detached path and will be SIGCONT'd there on unwind).
    let count = Int(gInflightCount)
    var i = 0
    while i < count && i < kInflightCapacity {
        _ = kill(gInflightPIDs[i], SIGCONT)
        i += 1
    }
    // Restore default disposition via sigaction (not signal(2)) — we
    // installed the handler via sigaction and mixing the two on the same
    // signal has undefined behavior on Darwin. Then re-raise so normal
    // termination proceeds.
    var act = sigaction()
    act.__sigaction_u = __sigaction_u(__sa_handler: SIG_DFL)
    sigemptyset(&act.sa_mask)
    act.sa_flags = 0
    sigaction(sig, &act, nil)
    raise(sig)
}
