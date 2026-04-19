import Foundation
import Darwin

/// Identifies who is asking the throttler to cap a process. Multiple sources
/// may want different duties on the same PID; the throttler applies the most
/// restrictive (lowest duty) across sources. This is how the per-app rule
/// engine and the system-wide governor coexist without fighting over PIDs
/// second-by-second.
enum ThrottleSource: Hashable {
    /// A user-defined `ThrottleRule` ("Chrome Helper ≤ 50%").
    case rule
    /// The `ThermalGovernor` reacting to a live cap breach.
    case governor
    /// Ad-hoc user request via the menu bar escape hatch
    /// ("Throttle frontmost app now"). Unlike `.rule`/`.governor` this
    /// source *bypasses* the foreground-duty floor — the whole point is
    /// to cap an app the user is actively looking at.
    case manual
}

/// Throttles running processes via SIGSTOP/SIGCONT duty cycling — a standard
/// Unix technique for rate-limiting a process without kernel extensions.
/// For each throttled PID, a background task cycles:
///
///     SIGSTOP for (1-duty)·period   → process is paused
///     SIGCONT for  duty   ·period   → process runs
///
/// A `duty` of 1.0 means "no throttle" (task is not started). A duty of 0.05
/// means the process runs only 5% of wall time. Period is ~100ms which is a
/// good balance between responsiveness and scheduler overhead.
///
/// Multiple sources (per-app rules, governor) can request different duties on
/// the same PID. The throttler applies `min(duty)` across sources so whichever
/// source wants the process slower wins — never the other way around. Sources
/// that no longer care about a PID call `clearDuty(source:for:)` rather than
/// `release()`, so other sources' requests remain in effect.
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
    nonisolated static let cyclePeriodMs: Int = 100
    /// Minimum / maximum duty accepted. 1.0 means "ignore / untrottle".
    nonisolated static let minDuty: Double = 0.05
    nonisolated static let maxDuty: Double = 1.0
    /// Soft floor applied when a throttle target is the foreground app.
    /// Throttling the app the user is actively interacting with produces
    /// audible stutter / input lag, so we clamp effective duty up to this
    /// value while it's frontmost. 0.85 ≈ 85% runtime, which is barely
    /// perceptible but still shaves load on a hot process.
    nonisolated static let foregroundDutyFloor: Double = 0.85

    /// Per-PID state. `task` is the cycler; `sources` maps each requester to
    /// its requested duty. The effective duty sent to the cycler each cycle
    /// is `min(sources.values)`. An empty `sources` means no one wants the
    /// PID throttled → release.
    private struct Entry {
        var sources: [ThrottleSource: Double]
        var name: String
        var task: Task<Void, Never>

        /// Most restrictive duty across all sources, clamped to `[minDuty, maxDuty]`.
        /// An entry should never exist with an empty sources map — release it first.
        var effectiveDuty: Double {
            sources.values.min() ?? ProcessThrottler.maxDuty
        }
    }

    private var active: [pid_t: Entry] = [:]
    /// Per-PID kqueue-backed watchers that fire on process exit. Registered
    /// the moment we start throttling a PID, cancelled the moment we stop.
    /// Closes the PID-reuse window (#19): without this we'd rely on the 1Hz
    /// snapshot to notice the PID is gone, and during that up-to-1s window
    /// the kernel may recycle the PID for an unrelated program. Sending
    /// SIGSTOP to the wrong process is the kind of bug that erodes trust
    /// fast. See `docs/engineering-references.md` §2 for the kqueue details.
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]
    private let currentUID: uid_t = getuid()

    /// Optional safety layer. Set by `ThermalStore` on startup. When present,
    /// the throttler reports in-flight PIDs to the dead-man's-switch file
    /// and the watchdog after every mutation.
    var safety: SafetyCoordinator?

    /// Refuse throttling of our own PID or any ancestor in our parent chain.
    /// Layered on top of the excluded-name list because ancestors are often
    /// generic process names (zsh, Terminal) that could slip past a name check.
    var protectAncestors: Bool = true

    /// PID of the app currently frontmost. Updated by `FrontmostAppObserver`.
    /// When set, the cycler uses `foregroundDutyFloor` as a lower bound on
    /// the effective duty for that PID — we never hammer the app the user
    /// is actively interacting with.
    var foregroundPID: pid_t? {
        didSet { if oldValue != foregroundPID { publishInflight() } }
    }

    /// Update the tracked foreground PID. Called by `ThermalStore` whenever
    /// `FrontmostAppObserver` fires.
    func setForegroundPID(_ pid: pid_t?) {
        foregroundPID = pid
    }

    // MARK: - Public API

    /// Request that `pid` run at `rawDuty` on behalf of `source`. Multiple
    /// sources may co-request — the effective cycle duty is `min()` across
    /// sources. If `rawDuty >= 1.0` this source's request is cleared (it no
    /// longer cares about the PID). Idempotent.
    func setDuty(_ rawDuty: Double,
                 for pid: pid_t,
                 name: String,
                 source: ThrottleSource) {
        guard pid > 0 else { return }
        // Safety: never throttle excluded system processes.
        if ProcessInspector.excludedNames.contains(name) {
            clearDuty(source: source, for: pid)
            return
        }
        // Safety: never touch processes we don't own.
        var uid: uid_t = 0
        if !ownedByCurrentUser(pid: pid, uidOut: &uid) {
            clearDuty(source: source, for: pid)
            return
        }
        // Safety: never throttle self or any ancestor (shell, launcher, etc.)
        if protectAncestors && SafetyCoordinator.isAncestorOrSelf(pid: pid) {
            clearDuty(source: source, for: pid)
            return
        }

        let duty = clamp(rawDuty, lo: Self.minDuty, hi: Self.maxDuty)
        // duty == maxDuty means "source no longer wants throttling" → clear
        // this source. Other sources' requests remain active.
        if duty >= Self.maxDuty {
            clearDuty(source: source, for: pid)
            return
        }

        if var existing = active[pid] {
            existing.sources[source] = duty
            existing.name = name  // keep the freshest display name
            active[pid] = existing
            return
        }

        // Spawn a new cycler with this source's request as the initial entry.
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runCycle(pid: pid)
        }
        active[pid] = Entry(sources: [source: duty], name: name, task: task)
        installExitWatcher(pid: pid)
        publishInflight()
    }

    /// Register a one-shot kqueue process source that fires the instant the
    /// kernel notes `pid` has exited. We release the PID before anyone else
    /// on this main actor can try to SIGSTOP a recycled PID.
    ///
    /// Process-source events can fire on an arbitrary dispatch queue on
    /// Apple Silicon (see engineering-references.md §2), so the handler hops
    /// back to the main actor before mutating `active`.
    private func installExitWatcher(pid: pid_t) {
        // Already watched? Don't stack sources.
        if exitWatchers[pid] != nil { return }
        let src = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            // Cancel immediately — .exit is one-shot, and cancelling from
            // within the handler is the idiomatic Swift pattern.
            src.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // If by some race another code path already released this
                // pid, `release` is a no-op.
                self.exitWatchers.removeValue(forKey: pid)
                self.release(pid: pid)
            }
        }
        src.resume()
        exitWatchers[pid] = src
    }

    /// Tear down an exit watcher if one exists. Called from `release(pid:)`
    /// and `releaseAll()` so we never leak process sources or double-fire.
    private func cancelExitWatcher(pid: pid_t) {
        if let src = exitWatchers.removeValue(forKey: pid) {
            src.cancel()
        }
    }

    /// Withdraw a specific source's request for this PID. If no source still
    /// wants the PID throttled, it's released. Rule engine / governor use
    /// this (not `release`) so they only retract their own requests.
    func clearDuty(source: ThrottleSource, for pid: pid_t) {
        guard var entry = active[pid] else { return }
        entry.sources.removeValue(forKey: source)
        if entry.sources.isEmpty {
            release(pid: pid)
        } else {
            active[pid] = entry
        }
    }

    /// Remove *all* requests from a single source. Used on engine
    /// teardown / pause so that source stops influencing any PID.
    func releaseSource(_ source: ThrottleSource) {
        let toUpdate = active.keys.filter { active[$0]?.sources.keys.contains(source) == true }
        for pid in toUpdate {
            clearDuty(source: source, for: pid)
        }
    }

    /// Release a single pid unconditionally — SIGCONT, cancel cycler, drop
    /// all source requests. Use sparingly; prefer `clearDuty` when you only
    /// want to retract one source's interest.
    func release(pid: pid_t) {
        guard let entry = active.removeValue(forKey: pid) else { return }
        entry.task.cancel()
        _ = kill(pid, SIGCONT)
        cancelExitWatcher(pid: pid)
        safety?.noteContinued(pid: pid)
        publishInflight()
    }

    /// Release everything. Call on teardown / when the rule engine disables.
    func releaseAll() {
        for (_, entry) in active {
            entry.task.cancel()
        }
        for (pid, _) in active {
            _ = kill(pid, SIGCONT)
        }
        active.removeAll()
        for (_, src) in exitWatchers { src.cancel() }
        exitWatchers.removeAll()
        safety?.resetStopTimestamps()
        publishInflight()
    }

    /// Push the current set of throttled PIDs to the safety layer so the
    /// dead-man's-switch file and signal-handler array stay in sync.
    private func publishInflight() {
        safety?.noteInflightChange(pids: Array(active.keys))
    }

    /// PIDs currently under active throttling, with their *effective* duty
    /// (min across sources) and the set of sources requesting the cap.
    var throttledPIDs: [(pid: pid_t, duty: Double, name: String)] {
        active.map { (pid: $0.key, duty: $0.value.effectiveDuty, name: $0.value.name) }
    }

    /// Full detail: which sources are requesting each pid, and at what duty.
    /// Used by UI to explain why a PID is throttled ("rule + governor").
    var throttleDetail: [(pid: pid_t, name: String, sources: [ThrottleSource: Double])] {
        active.map { (pid: $0.key, name: $0.value.name, sources: $0.value.sources) }
    }

    /// Is this pid currently throttled by any source?
    func isThrottled(pid: pid_t) -> Bool { active[pid] != nil }

    /// Is this pid throttled by a specific source?
    func isThrottled(pid: pid_t, by source: ThrottleSource) -> Bool {
        active[pid]?.sources[source] != nil
    }

    // MARK: - Cycler

    /// Main loop for a single pid. Reads the latest duty each iteration so
    /// updates take effect within one cycle.
    private func runCycle(pid: pid_t) async {
        let periodNs: UInt64 = UInt64(Self.cyclePeriodMs) * 1_000_000

        while !Task.isCancelled {
            // Snapshot current duty (may have been updated by setDuty).
            // If this pid is the frontmost app, soften duty up to the
            // foreground floor so the user's active window isn't being
            // SIGSTOP'd mid-keystroke.
            let duty: Double = await MainActor.run {
                guard let entry = active[pid] else { return Self.maxDuty }
                let base = entry.effectiveDuty
                // Apply foreground floor unless the only requester is the
                // ad-hoc manual escape hatch — the user explicitly asked for
                // the frontmost app to be throttled.
                let onlyManual = entry.sources.keys.allSatisfy { $0 == .manual }
                if pid == foregroundPID && !onlyManual {
                    return max(base, Self.foregroundDutyFloor)
                }
                return base
            }
            if duty >= Self.maxDuty { return }

            let runNs  = UInt64(Double(periodNs) * duty)
            let stopNs = periodNs &- runNs

            // RUN phase: ensure SIGCONT, sleep run-slice.
            if !signal(SIGCONT, to: pid) { return }
            await MainActor.run { self.safety?.noteContinued(pid: pid) }
            if runNs > 0 {
                try? await Task.sleep(nanoseconds: runNs)
            }
            if Task.isCancelled { _ = kill(pid, SIGCONT); return }

            // STOP phase: SIGSTOP, sleep stop-slice.
            if stopNs > 0 {
                if !signal(SIGSTOP, to: pid) { return }
                await MainActor.run { self.safety?.noteStopped(pid: pid) }
                try? await Task.sleep(nanoseconds: stopNs)
            }
        }
        // On cancellation, always resume the process.
        _ = kill(pid, SIGCONT)
        await MainActor.run { self.safety?.noteContinued(pid: pid) }
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
