import Foundation
import Darwin

/// Enumerates running processes and computes their CPU% via libproc.
/// Call `snapshot()` periodically; it tracks delta CPU time against the
/// previous snapshot to compute percent (cumulative → instantaneous).
@MainActor
final class ProcessInspector {
    /// Processes that we never target, regardless of any rule. System-critical
    /// or interactive-UX processes where SIGSTOP would hurt more than help.
    /// Matched against executable name (case-sensitive).
    /// Truly opaque system processes that should never appear in any
    /// user-facing list. These are the OS, not the user's work — the
    /// user has nothing actionable to do with `kernel_task`. Both the
    /// governor's targeting list AND the visibility surfaces filter
    /// against this set.
    static let systemHiddenNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "coreaudiod", "hidd",
        "ControlCenter", "SystemUIServer", "Dock", "Finder", "loginwindow",
        "backboardd", "runningboardd", "cfprefsd", "mds", "mds_stores",
        "mdworker", "mdworker_shared", "bluetoothd", "powerd", "logd",
        "Spotlight", "UserEventAgent", "distnoted", "sharingd", "securityd",
        "trustd", "syspolicyd",
        "AirAssist", "airassist-rescue",  // ourselves
    ]

    /// Processes the user can SEE in visibility surfaces but that are
    /// never auto-throttled and shouldn't be manually capped either.
    /// SIGSTOPing one of these is catastrophic — Xcode mid-build, a
    /// terminal running a long script, the agent currently running the
    /// user's session. The visibility surfaces show these with a
    /// "Protected" badge instead of a Cap button, so the user can see
    /// the load they're contributing without having a footgun
    /// available.
    static let userProtectedNames: Set<String> = [
        "Xcode", "Simulator",
        "Claude", "claude",  // Claude Code itself
        "Codex",  // Codex CLI agent
        "Terminal", "iTerm2", "Warp", "Ghostty",
    ]

    /// Combined list — kept as the original `excludedNames` API for
    /// back-compat. The governor's snapshot publisher used to call
    /// through this; the rule engine and ProcessThrottler still do.
    /// New visibility-friendly callers should use the narrower
    /// `systemHiddenNames` directly.
    static let excludedNames: Set<String> = systemHiddenNames.union(userProtectedNames)

    /// Whether this process is in the `userProtectedNames` set —
    /// visible to the user but never throttle-able. Visibility
    /// surfaces use this to render a "Protected" badge in place of
    /// the Cap action.
    static func isProtected(_ name: String) -> Bool {
        userProtectedNames.contains(name)
    }

    private var lastSnapshot: [pid_t: (cpuTimeNs: UInt64, wallTime: Date)] = [:]
    /// Pre-resolved bundle IDs, keyed by executable path (stable across snapshots).
    private var bundleIDCache: [String: String] = [:]

    private let currentUID: uid_t = getuid()

    /// Take a fresh snapshot of all processes. CPU% is computed from the
    /// delta of cpuTimeNs between this call and the previous one. For newly
    /// seen processes, cpuPercent is 0 until the next snapshot.
    func snapshot() -> [RunningProcess] {
        let pids = enumeratePIDs()
        let now = Date()
        var out: [RunningProcess] = []
        out.reserveCapacity(pids.count)

        var newSnapshot: [pid_t: (UInt64, Date)] = [:]

        for pid in pids where pid > 0 {
            guard let info = procInfo(pid: pid) else { continue }
            let cpuTimeNs = info.userTime + info.sysTime
            newSnapshot[pid] = (cpuTimeNs, now)

            // Delta from previous
            let percent: Double = {
                guard let prev = lastSnapshot[pid] else { return 0 }
                let dtNs = cpuTimeNs > prev.cpuTimeNs
                    ? cpuTimeNs - prev.cpuTimeNs : 0
                let dtWall = now.timeIntervalSince(prev.wallTime)
                guard dtWall > 0 else { return 0 }
                // cpuTime/wallTime = fraction of one core used; × 100 = percent.
                return Double(dtNs) / 1_000_000_000.0 / dtWall * 100.0
            }()

            let path    = pathFor(pid: pid)
            let bundle  = path.flatMap { resolveBundleID(path: $0) }

            out.append(
                RunningProcess(
                    id: pid,
                    name: info.name,
                    bundleID: bundle,
                    executablePath: path,
                    parentPID: info.parentPID,
                    uid: info.uid,
                    isCurrentUser: info.uid == currentUID,
                    cpuTimeNs: cpuTimeNs,
                    cpuPercent: percent,
                    rssBytes: info.rssBytes
                )
            )
        }

        lastSnapshot = newSnapshot
        return out
    }

    /// Top-N processes by current CPU%, filtering excluded names and non-user procs.
    /// Returns an array sorted high→low.
    /// Used by the governor and rule engine for THROTTLE-TARGETING —
    /// excludes both system-hidden (kernel_task etc.) and
    /// user-protected (Xcode etc.) names so neither subsystem ever
    /// tries to SIGSTOP something dangerous.
    func topUserProcessesByCPU(limit: Int = 10,
                               minPercent: Double = 0.0) -> [RunningProcess] {
        let s = snapshot()
        return s
            .filter { $0.isCurrentUser }
            .filter { !ProcessInspector.excludedNames.contains($0.name) }
            .filter { $0.cpuPercent >= minPercent }
            .sorted  { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { $0 }
    }

    /// Top-N processes by current CPU%, with the lighter exclusion
    /// list — only `systemHiddenNames` (kernel_task, launchd,
    /// WindowServer, etc.). User-protected names like Xcode and
    /// Terminal stay in the result so the user can see their load.
    /// Visibility surfaces (popover CPU Activity, dashboard Top CPU
    /// consumers, Throttling-prefs Top CPU consumers, the persistent
    /// `cpu-activity.ndjson` log) use this; throttle code paths use
    /// `topUserProcessesByCPU` so the targeting set still excludes
    /// everything dangerous.
    func topVisibleProcessesByCPU(limit: Int = 10,
                                  minPercent: Double = 0.0) -> [RunningProcess] {
        snapshot()
            .filter { $0.isCurrentUser }
            .filter { !ProcessInspector.systemHiddenNames.contains($0.name) }
            .filter { $0.cpuPercent >= minPercent }
            .sorted  { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { $0 }
    }

    /// Total CPU% across non-excluded user processes (useful for cpu-cap governor).
    func totalUserCPUPercent() -> Double {
        snapshot()
            .filter { $0.isCurrentUser }
            .filter { !ProcessInspector.excludedNames.contains($0.name) }
            .reduce(0) { $0 + $1.cpuPercent }
    }

    // MARK: - Private: libproc wrappers

    private func enumeratePIDs() -> [pid_t] {
        // Determine buffer size
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<pid_t>.size
        var buf = [pid_t](repeating: 0, count: count)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf, Int32(size))
        guard written > 0 else { return [] }
        let actualCount = Int(written) / MemoryLayout<pid_t>.size
        return Array(buf.prefix(actualCount))
    }

    private struct ProcInfo {
        let name: String
        let parentPID: pid_t
        let uid: uid_t
        let userTime: UInt64
        let sysTime: UInt64
        let rssBytes: UInt64
    }

    private func procInfo(pid: pid_t) -> ProcInfo? {
        // Task info: cpu, memory
        var taskInfo = proc_taskinfo()
        let taskSize = MemoryLayout<proc_taskinfo>.size
        let taskRet = withUnsafeMutablePointer(to: &taskInfo) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ptr, Int32(taskSize))
        }
        guard taskRet == Int32(taskSize) else { return nil }

        // BSD info: name, parent pid, uid
        var bsd = proc_bsdinfo()
        let bsdSize = MemoryLayout<proc_bsdinfo>.size
        let bsdRet = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(bsdSize))
        }
        guard bsdRet == Int32(bsdSize) else { return nil }

        // Extract name (16-byte proc name). Copy out to avoid overlapping access.
        var comm = bsd.pbi_comm
        let commSize = MemoryLayout.size(ofValue: comm)
        let name = withUnsafePointer(to: &comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: commSize) {
                String(cString: $0)
            }
        }

        return ProcInfo(
            name: name,
            parentPID: pid_t(bsd.pbi_ppid),
            uid: bsd.pbi_uid,
            userTime: taskInfo.pti_total_user,
            sysTime: taskInfo.pti_total_system,
            rssBytes: UInt64(taskInfo.pti_resident_size)
        )
    }

    private func pathFor(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN; MAXPATHLEN = 1024.
        let bufSize = 4 * 1024
        var buf = [CChar](repeating: 0, count: bufSize)
        let written = proc_pidpath(pid, &buf, UInt32(bufSize))
        guard written > 0 else { return nil }
        return String(cString: buf)
    }

    private func resolveBundleID(path: String) -> String? {
        if let cached = bundleIDCache[path] { return cached }
        // Walk up from executable path to find the .app container.
        // `/Applications/Foo.app/Contents/MacOS/Foo` → `/Applications/Foo.app`
        var url = URL(fileURLWithPath: path)
        while url.pathExtension != "app" && url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier
        else {
            return nil
        }
        bundleIDCache[path] = id
        return id
    }
}
