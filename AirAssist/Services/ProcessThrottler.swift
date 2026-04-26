import Foundation
import Darwin
import os

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
    fileprivate struct Entry: Sendable {
        var sources: [ThrottleSource: Double]
        var name: String
        var task: Task<Void, Never>

        /// Most restrictive duty across all sources, clamped to `[minDuty, maxDuty]`.
        /// An entry should never exist with an empty sources map — release it first.
        var effectiveDuty: Double {
            sources.values.min() ?? ProcessThrottler.maxDuty
        }
    }

    /// Lock-guarded shared state read by the off-main cycler.
    ///
    /// The cycler used to be `Task.detached { await self.runCycle(...) }` on
    /// a `@MainActor` method, which silently hopped the entire duty-cycle
    /// loop onto the main actor. If main hung, the cycler hung with it, and
    /// the watchdog stopped seeing `noteStopped` heartbeats — exactly the
    /// scenario the watchdog was designed to catch. (Audit Tier 0 item 1;
    /// Codex flagged this as bigger than the original "drop three
    /// MainActor.run hops" framing.)
    ///
    /// The fix: hold `active` and `foregroundPID` behind an
    /// `OSAllocatedUnfairLock` so the cycler can read them without any
    /// actor hop, and call `safety.noteStopped/noteContinued` (already
    /// nonisolated) directly. Main-actor mutators continue to use the lock
    /// to write — there is one source of truth.
    fileprivate struct SharedState: Sendable {
        var active: [pid_t: Entry] = [:]
        var foregroundPID: pid_t? = nil
    }
    nonisolated fileprivate let state = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    /// Per-PID kqueue-backed watchers that fire on process exit. Registered
    /// the moment we start throttling a PID, cancelled the moment we stop.
    /// Closes the PID-reuse window (#19): without this we'd rely on the 1Hz
    /// snapshot to notice the PID is gone, and during that up-to-1s window
    /// the kernel may recycle the PID for an unrelated program. Sending
    /// SIGSTOP to the wrong process is the kind of bug that erodes trust
    /// fast. See `docs/engineering-references.md` §2 for the kqueue details.
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]
    nonisolated private let currentUID: uid_t = getuid()

    /// Optional safety layer. Set by `ThermalStore` on startup, never
    /// reassigned, never cleared. Marked `nonisolated(unsafe)` so the
    /// off-main cycler can call its (nonisolated) heartbeat methods
    /// without an actor hop. The set-once invariant is the safety
    /// argument: a single pointer-sized assignment from main during init,
    /// followed by reads from the cycler — well-defined on arm64.
    nonisolated(unsafe) var safety: SafetyCoordinator?

    /// Refuse throttling of our own PID or any ancestor in our parent chain.
    /// Layered on top of the excluded-name list because ancestors are often
    /// generic process names (zsh, Terminal) that could slip past a name check.
    var protectAncestors: Bool = true

    /// PID of the app currently frontmost. Updated by `FrontmostAppObserver`.
    /// When set, the cycler uses `foregroundDutyFloor` as a lower bound on
    /// the effective duty for that PID — we never hammer the app the user
    /// is actively interacting with.
    var foregroundPID: pid_t? {
        get { state.withLock { $0.foregroundPID } }
    }

    /// Update the tracked foreground PID. Called by `ThermalStore` whenever
    /// `FrontmostAppObserver` fires.
    func setForegroundPID(_ pid: pid_t?) {
        let changed = state.withLock { s -> Bool in
            let was = s.foregroundPID
            s.foregroundPID = pid
            return was != pid
        }
        if changed { publishInflight() }
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
        guard pid > 0 else {
            Self.logger.error("setDuty rejected: pid=\(pid, privacy: .public) (non-positive)")
            return
        }
        // Safety: convenience allowlist that protects dev tools and a few
        // terminal apps from accidental auto-throttle by rules and the
        // governor. Explicit `.manual` clicks are user intent — bypass
        // this list. The hard rails (own-user, no-ancestor, no-self)
        // below still apply to everyone.
        if source != .manual && ProcessInspector.excludedNames.contains(name) {
            Self.logger.notice("setDuty rejected: pid=\(pid) name=\(name, privacy: .public) (excluded system process)")
            clearDuty(source: source, for: pid)
            return
        }
        // Safety: never touch processes we don't own.
        var uid: uid_t = 0
        if !ownedByCurrentUser(pid: pid, uidOut: &uid) {
            Self.logger.notice("setDuty rejected: pid=\(pid) name=\(name, privacy: .public) (not owned by current user, uid=\(uid))")
            clearDuty(source: source, for: pid)
            return
        }
        // Safety: never throttle self or any ancestor (shell, launcher, etc.)
        if protectAncestors && SafetyCoordinator.isAncestorOrSelf(pid: pid) {
            Self.logger.notice("setDuty rejected: pid=\(pid) name=\(name, privacy: .public) (ancestor or self)")
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

        let updated = state.withLock { s -> Bool in
            if var existing = s.active[pid] {
                existing.sources[source] = duty
                existing.name = name  // keep the freshest display name
                s.active[pid] = existing
                return true
            }
            return false
        }
        if updated { return }

        // SAFETY ORDERING — persist intent BEFORE spawning the cycler.
        //
        // The cycler may SIGSTOP this pid within its first ~1ms of dispatch.
        // If we spawn the task first and write the inflight file second, a
        // crash in that window leaves a process SIGSTOP'd with no record on
        // disk — `recoverOnLaunch` won't SIGCONT it next launch, and the
        // user's process is frozen forever. Publishing inflight first means
        // the worst case is: we record a pid we never actually stopped →
        // `recoverOnLaunch` sends a redundant SIGCONT to a running process,
        // which is a no-op.
        //
        // We stage the Entry with a placeholder task, publish, then install
        // the real cycler. Exit watcher is installed before the cycler runs
        // so pid reuse cannot race us.
        let placeholder = Task<Void, Never> { }
        state.withLock { $0.active[pid] = Entry(sources: [source: duty], name: name, task: placeholder) }
        installExitWatcher(pid: pid)
        publishInflight() // <-- inflight file is fsync'd before cycler can SIGSTOP

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            self.runCycle(pid: pid)
        }
        // Replace the placeholder with the real cycler task. The cycler
        // reads duty via the lock, so it won't begin SIGSTOP'ing until this
        // store completes.
        let stillStaged = state.withLock { s -> Bool in
            if var e = s.active[pid] {
                e.task = task
                s.active[pid] = e
                return true
            }
            return false
        }
        if !stillStaged {
            // Released between publish and here (extremely rare reentrancy).
            // Cancel the cycler we just spawned.
            task.cancel()
        }
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
        // The handler MUST be `@Sendable` (i.e., non-main-actor-isolated):
        // this class is `@MainActor`, and under Swift 6 strict concurrency
        // closures created inside `@MainActor` methods inherit main-actor
        // isolation by default. But Dispatch fires the handler on the
        // utility queue — so at runtime Swift's
        // `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue` trips
        // SIGTRAP. Binding the closure to a `@Sendable` typed `let` forces
        // it non-isolated; the main-actor work still happens inside the
        // inner `Task { @MainActor ... }` hop. `pid` is `pid_t` (Sendable);
        // `DispatchSourceProcess` is thread-safe so capturing `src` to
        // call `.cancel()` from the handler is fine.
        let handler: @Sendable () -> Void = { [weak self] in
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
        src.setEventHandler(handler: handler)
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
        let shouldRelease = state.withLock { s -> Bool in
            guard var entry = s.active[pid] else { return false }
            entry.sources.removeValue(forKey: source)
            if entry.sources.isEmpty {
                // Defer the release to outside the lock so we don't reenter.
                return true
            } else {
                s.active[pid] = entry
                return false
            }
        }
        if shouldRelease { release(pid: pid) }
    }

    /// Remove *all* requests from a single source. Used on engine
    /// teardown / pause so that source stops influencing any PID.
    func releaseSource(_ source: ThrottleSource) {
        let toUpdate = state.withLock { s in
            s.active.keys.filter { s.active[$0]?.sources.keys.contains(source) == true }
        }
        for pid in toUpdate {
            clearDuty(source: source, for: pid)
        }
    }

    /// Release a single pid unconditionally — SIGCONT, cancel cycler, drop
    /// all source requests. Use sparingly; prefer `clearDuty` when you only
    /// want to retract one source's interest.
    func release(pid: pid_t) {
        let removed = state.withLock { $0.active.removeValue(forKey: pid) }
        guard let entry = removed else { return }
        entry.task.cancel()
        resumeWithRetry(pid: pid, name: entry.name)
        cancelExitWatcher(pid: pid)
        safety?.noteContinued(pid: pid)
        publishInflight()
    }

    /// Release everything. Call on teardown / when the rule engine disables.
    func releaseAll() {
        // Snapshot before mutating so retry tasks capture stable pid/name
        // pairs even if `active` is mutated mid-loop.
        let snapshot: [(pid: pid_t, name: String, task: Task<Void, Never>)] = state.withLock { s in
            let items = s.active.map { (pid: $0.key, name: $0.value.name, task: $0.value.task) }
            s.active.removeAll()
            return items
        }
        for item in snapshot { item.task.cancel() }
        for item in snapshot {
            resumeWithRetry(pid: item.pid, name: item.name)
        }
        for (_, src) in exitWatchers { src.cancel() }
        exitWatchers.removeAll()
        safety?.resetStopTimestamps()
        publishInflight()
    }

    /// Send SIGCONT with retry on EPERM and user-visible alert on final
    /// failure. ESRCH (process already gone) is not a failure. Any other
    /// error gets up to 3 retries on a background task with 50ms spacing;
    /// if all fail, surface an alert so the user knows a process may be
    /// stuck in `T` state and has a one-click path to Activity Monitor.
    ///
    /// Silently accepting EPERM on SIGCONT was the single highest-severity
    /// failure mode in the codebase: any sandbox/TCC regression = a
    /// permanently-frozen user process with no feedback whatsoever.
    private func resumeWithRetry(pid: pid_t, name: String) {
        let immediate = kill(pid, SIGCONT)
        if immediate == 0 { return }
        let err = errno
        if err == ESRCH { return }
        // Retry on a detached task so we don't block the main actor.
        Task.detached(priority: .utility) {
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                if kill(pid, SIGCONT) == 0 { return }
                if errno == ESRCH { return }
            }
            let finalErrno = errno
            await MainActor.run {
                SIGCONTFailureAlert.report(pid: pid, name: name, errno: finalErrno)
            }
        }
    }

    /// Push the current set of throttled PIDs to the safety layer so the
    /// dead-man's-switch file and signal-handler array stay in sync.
    private func publishInflight() {
        let pids = state.withLock { Array($0.active.keys) }
        safety?.noteInflightChange(pids: pids)
    }

    /// PIDs currently under active throttling, with their *effective* duty
    /// (min across sources) and the set of sources requesting the cap.
    var throttledPIDs: [(pid: pid_t, duty: Double, name: String)] {
        state.withLock { s in
            s.active.map { (pid: $0.key, duty: $0.value.effectiveDuty, name: $0.value.name) }
        }
    }

    /// Full detail: which sources are requesting each pid, and at what duty.
    /// Used by UI to explain why a PID is throttled ("rule + governor").
    var throttleDetail: [(pid: pid_t, name: String, sources: [ThrottleSource: Double])] {
        state.withLock { s in
            s.active.map { (pid: $0.key, name: $0.value.name, sources: $0.value.sources) }
        }
    }

    /// Is this pid currently throttled by any source?
    func isThrottled(pid: pid_t) -> Bool {
        state.withLock { $0.active[pid] != nil }
    }

    /// Is this pid throttled by a specific source?
    func isThrottled(pid: pid_t, by source: ThrottleSource) -> Bool {
        state.withLock { $0.active[pid]?.sources[source] != nil }
    }

    // MARK: - Cycler

    /// Main loop for a single pid. Reads the latest duty each iteration so
    /// updates take effect within one cycle.
    ///
    /// `nonisolated` so it runs entirely off the main actor — without this,
    /// the duty-cycle loop would inherit `@MainActor` from the class and
    /// every iteration would block on main responsiveness. The watchdog
    /// design depends on `safety.noteStopped/noteContinued` heartbeats
    /// continuing even when main is hung; that only works if the cycler is
    /// genuinely off-main. Shared state (`active`, `foregroundPID`) is read
    /// via the lock-guarded `state`; `safety` is a set-once reference safe
    /// to read directly.
    nonisolated private func runCycle(pid: pid_t) {
        let periodNs: UInt64 = UInt64(Self.cyclePeriodMs) * 1_000_000

        while !Task.isCancelled {
            // Snapshot current duty (may have been updated by setDuty).
            // If this pid is the frontmost app, soften duty up to the
            // foreground floor so the user's active window isn't being
            // SIGSTOP'd mid-keystroke.
            let duty: Double = state.withLock { s in
                guard let entry = s.active[pid] else { return Self.maxDuty }
                let base = entry.effectiveDuty
                // Apply foreground floor unless the only requester is the
                // ad-hoc manual escape hatch — the user explicitly asked for
                // the frontmost app to be throttled.
                let onlyManual = entry.sources.keys.allSatisfy { $0 == .manual }
                if pid == s.foregroundPID && !onlyManual {
                    return max(base, Self.foregroundDutyFloor)
                }
                return base
            }
            if duty >= Self.maxDuty { return }

            let runNs  = UInt64(Double(periodNs) * duty)
            let stopNs = periodNs &- runNs

            // RUN phase: ensure SIGCONT, sleep run-slice.
            if !signal(SIGCONT, to: pid) { return }
            safety?.noteContinued(pid: pid)
            if runNs > 0 {
                blockingSleep(nanoseconds: runNs)
            }
            if Task.isCancelled { _ = kill(pid, SIGCONT); return }

            // STOP phase: SIGSTOP, sleep stop-slice.
            if stopNs > 0 {
                // Re-check cancellation and that this pid is still in the
                // active map right before we issue SIGSTOP. Closes a narrow
                // race where `release(pid:)` ran between the duty read above
                // and here — without this check we'd SIGSTOP a pid the
                // throttler thinks it's already released (and for which the
                // exit watcher may have been cancelled).
                if Task.isCancelled { _ = kill(pid, SIGCONT); return }
                let stillActive = state.withLock { $0.active[pid] != nil }
                if !stillActive { return }
                if !signal(SIGSTOP, to: pid) { return }
                safety?.noteStopped(pid: pid)
                blockingSleep(nanoseconds: stopNs)
            }
        }
        // On cancellation, always resume the process.
        _ = kill(pid, SIGCONT)
        safety?.noteContinued(pid: pid)
    }

    /// Off-main blocking sleep. We can't use `Task.sleep` here because the
    /// cycler is now synchronous (intentionally — keeps it off the actor
    /// hop machinery). `nanosleep` is the cheapest portable equivalent and
    /// honors signal interruption, which we ignore (the wake-up only costs
    /// us a slightly shortened phase).
    nonisolated private func blockingSleep(nanoseconds: UInt64) {
        var ts = timespec(tv_sec: Int(nanoseconds / 1_000_000_000),
                          tv_nsec: Int(nanoseconds % 1_000_000_000))
        var rem = timespec()
        while nanosleep(&ts, &rem) == -1 && errno == EINTR {
            ts = rem
        }
    }

    /// Sends `sig` to `pid`. Returns false if the process is gone (ESRCH) or
    /// another unrecoverable error — caller should stop the cycler.
    ///
    /// We log non-ESRCH failures (EPERM in particular) once per (pid, signal,
    /// errno) tuple so a TCC regression or sandbox change doesn't silently
    /// degrade the throttler — diagnosis materially improves when the same
    /// failure class isn't collapsed with "process exited normally". (audit
    /// Tier 0 item 5; Codex VERIFIED.)
    ///
    /// Nonisolated so the off-main cycler can call it without an actor hop.
    nonisolated private func signal(_ sig: Int32, to pid: pid_t) -> Bool {
        let r = kill(pid, sig)
        if r == 0 { return true }
        let err = errno
        if err == ESRCH { return false } // process died; unwind silently.
        let key = SignalFailureKey(pid: pid, signal: sig, errno: err)
        let firstTime = Self.loggedSignalFailures.withLock { $0.insert(key).inserted }
        if firstTime {
            Self.logger.error(
                "kill(\(pid, privacy: .public), \(sig, privacy: .public)) failed: errno=\(err, privacy: .public) (\(String(cString: strerror(err)), privacy: .public))"
            )
        }
        return false
    }

    nonisolated private struct SignalFailureKey: Hashable, Sendable { let pid: pid_t; let signal: Int32; let errno: Int32 }
    /// Lock-guarded so this stays correct now that the cycler runs off the
    /// main actor and calls `signal()` directly.
    nonisolated private static let loggedSignalFailures = OSAllocatedUnfairLock<Set<SignalFailureKey>>(initialState: [])
    nonisolated private static let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                                    category: "ProcessThrottler")

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
