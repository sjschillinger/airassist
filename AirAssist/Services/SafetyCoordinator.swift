import Foundation
import Darwin

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
///    async-signal-safe; the inflight list lives in a C array specifically so
///    the handler can read it without locking.
///
/// 3. **Watchdog.** 1Hz main-actor task; if any PID has been continuously
///    SIGSTOP'd for longer than `maxPauseMs` (default 500ms), force SIGCONT.
///    Protects against a stuck cycler loop or runaway duty-cycle error.
///
/// Own-process-tree protection lives inline in `ProcessThrottler.setDuty`
/// via `SafetyCoordinator.isAncestorOrSelf(pid:)`.
@MainActor
final class SafetyCoordinator {

    // MARK: - Configuration

    /// Maximum continuous SIGSTOP duration before the watchdog intervenes.
    static let watchdogMaxPauseMs: Int = 500
    /// Watchdog tick period.
    static let watchdogTickMs: Int = 250

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

    /// Called on every throttler mutation. Rewrites the inflight file.
    static func writeInflight(pids: [pid_t]) {
        let url = inflightFileURL
        if pids.isEmpty {
            try? FileManager.default.removeItem(at: url)
            updateSignalHandlerPIDs([])
            return
        }
        let rec = InflightRecord(pids: pids.map { Int32($0) }, writtenAt: Date())
        if let data = try? JSONEncoder().encode(rec) {
            try? data.write(to: url, options: .atomic)
        }
        updateSignalHandlerPIDs(pids)
    }

    /// Call very early in app launch (before starting any throttler). Reads
    /// the inflight file left by a previous session, SIGCONTs every PID,
    /// then deletes the file. Safe to call if the file doesn't exist.
    static func recoverOnLaunch() {
        let url = inflightFileURL
        guard let data = try? Data(contentsOf: url),
              let rec  = try? JSONDecoder().decode(InflightRecord.self, from: data)
        else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        for pid in rec.pids {
            // kill() returns ESRCH if pid is gone — fine, move on.
            _ = kill(pid_t(pid), SIGCONT)
        }
        try? FileManager.default.removeItem(at: url)
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

    // MARK: - Watchdog

    private var watchdogTask: Task<Void, Never>?
    private var stopTimestamps: [pid_t: Date] = [:]

    /// Report that the cycler just issued SIGSTOP for a pid. Called from
    /// `ProcessThrottler` — updates the "last paused at" time used by the
    /// watchdog.
    func noteStopped(pid: pid_t) {
        stopTimestamps[pid] = Date()
    }

    /// Report that the cycler just issued SIGCONT for a pid.
    func noteContinued(pid: pid_t) {
        stopTimestamps.removeValue(forKey: pid)
    }

    /// Clear all stop timestamps (called on releaseAll).
    func resetStopTimestamps() {
        stopTimestamps.removeAll()
    }

    /// Called by `ProcessThrottler` after any mutation to the active set.
    /// Updates both the on-disk dead-man's-switch file and the in-memory
    /// signal-handler PID array.
    func noteInflightChange(pids: [pid_t]) {
        Self.writeInflight(pids: pids)
    }

    func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            let period: UInt64 = UInt64(Self.watchdogTickMs) * 1_000_000
            let limit = TimeInterval(Self.watchdogMaxPauseMs) / 1000.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: period)
                guard let self else { return }
                let now = Date()
                for (pid, stoppedAt) in self.stopTimestamps
                where now.timeIntervalSince(stoppedAt) > limit {
                    // Stuck — force-continue and forget. Cycler will re-stop
                    // it on the next iteration if still applicable; meanwhile
                    // the process is not locked up.
                    _ = kill(pid, SIGCONT)
                    self.stopTimestamps.removeValue(forKey: pid)
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
// in-flight PIDs in a plain C array updated from the main actor; the handler
// just iterates and sends SIGCONT. `kill(2)` is async-signal-safe.

private let kInflightCapacity: Int = 256
nonisolated(unsafe) private var gInflightPIDs  = [pid_t](repeating: 0, count: kInflightCapacity)
nonisolated(unsafe) private var gInflightCount: Int = 0

/// Update the signal-handler-visible PID list. Runs on the main actor from
/// `writeInflight`; the signal handler reads without locking (benign race —
/// worst case we miss or double-send SIGCONT, both harmless).
fileprivate func updateSignalHandlerPIDs(_ pids: [pid_t]) {
    let n = min(pids.count, kInflightCapacity)
    for i in 0..<n { gInflightPIDs[i] = pids[i] }
    gInflightCount = n
}

/// C-compatible signal handler. Releases every pid then re-raises with
/// default disposition so the process exits.
@_cdecl("airAssistSignalHandler")
fileprivate func airAssistSignalHandler(_ sig: Int32) {
    let count = gInflightCount
    var i = 0
    while i < count && i < kInflightCapacity {
        _ = kill(gInflightPIDs[i], SIGCONT)
        i += 1
    }
    // Restore default and re-raise so normal termination proceeds.
    signal(sig, SIG_DFL)
    raise(sig)
}
