# Engineering references

A map to the canonical sources for the tricky system-level behaviors
AirAssist depends on. **Not a tutorial.** When something seems wrong,
look here first — it will tell you which manpage, Apple doc, or
header file to read before improvising.

Kept intentionally short. Each entry is: what it is · where the real
spec lives · known gotchas we've hit. Add a new entry when (and only
when) we start depending on a new tricky thing.

---

## 1. SIGSTOP / SIGCONT process duty cycling

The core of our throttling mechanism. `ProcessThrottler` cycles
SIGSTOP (pause) and SIGCONT (resume) on target PIDs to rate-limit
them without kernel extensions.

**Canonical sources:**
- `man 2 kill`, `man 3 signal`, `man 7 signal` (Darwin)
- `man 1 ps` — look for the `STAT` column codes, specifically:
  - `R` running · `S` interruptible sleep · `T` **stopped** ·
    `Z` zombie · `U` uninterruptible wait
- POSIX.1-2017 §11.1 (signal concepts)
- xnu source: `bsd/kern/kern_sig.c` — authoritative for what Darwin
  actually does with stop/cont

**Known gotchas:**
- `SIGSTOP` and `SIGKILL` are the only two signals that cannot be
  caught, blocked, or ignored by the target. `SIGCONT` can be caught
  but always resumes a stopped process even if the handler is a no-op.
- A process being SIGSTOPed causes its parent to receive `SIGCHLD`
  with `WIFSTOPPED(status) == true`. Parent shells may notice and
  print "[1]+ Stopped …" — harmless but visible in interactive
  terminals.
- If a process is ptraced (debugger attached, Instruments, sampling)
  SIGCONT may not actually resume it — the tracer is holding it.
  Throttling debugger-attached processes is not supported.
- `kill(pid, 0)` is the standard liveness probe (returns 0 if alive,
  -1 + errno=ESRCH if dead). We use this in `MenuBarPopoverView` to
  filter stale throttled rows.
- Never SIGSTOP `launchd` (pid 1), `WindowServer`, or any kernel
  task. `ProcessInspector.excludedNames` is the allowlist; keep it
  updated when Apple adds new critical system processes.

---

## 2. kqueue `EVFILT_PROC` for PID liveness + process-exit events

Needed for #19 (PID reuse / process-exit mid-throttle). The plan is
to register a process-exit source for every throttled PID so we
never send SIGSTOP to a recycled PID that a different program now
holds.

**Canonical sources:**
- `man 2 kqueue`, `man 2 kevent` — the kernel filter details
- Filter flags: `NOTE_EXIT`, `NOTE_FORK`, `NOTE_EXEC`, `NOTE_SIGNAL`,
  `NOTE_EXITSTATUS` (macOS-specific, exit code in `data`)
- Swift-native wrapper: `DispatchSource.makeProcessSource(identifier:
  pid_t, eventMask: DispatchSource.ProcessEvent, queue:)`
  — Apple Developer docs under `DispatchSource` /
  `DispatchSourceProcess`
- Reference implementation patterns: look at how `PMEventHandler` /
  `NSRunningApplication` observe process lifecycle (mostly higher-
  level, but the primitives are the same).

**Known gotchas:**
- The kqueue process source requires permission to observe the pid.
  For another user's pid we get `EPERM`; for ours we don't. We only
  throttle our own uid so this is moot.
- A process source is one-shot on `.exit`: once fired, cancel it.
  The idiomatic Swift pattern is
  `source.setEventHandler { source.cancel(); … }`.
- PID reuse is real and happens quickly on busy systems. Without
  NOTE_EXIT we rely on the 1 Hz snapshot, which gives up to a 1s
  window where SIGSTOP could hit a recycled PID. NOTE_EXIT closes
  that window.
- On Apple Silicon, process events can fire on a different queue
  than you registered on — treat the handler as arbitrary-queue and
  hop to `@MainActor` explicitly.

---

## 3. NSWorkspace sleep / wake notifications

Needed for #18. We'll observe `willSleep` to decide whether to
release throttled processes before sleep, and `didWake` to re-arm.

**Canonical sources:**
- `NSWorkspace` class reference, sections "Responding to Application
  Changes" and "Responding to System Changes"
- `NSWorkspace.willSleepNotification` · `didWakeNotification` ·
  `screensDidSleepNotification` · `screensDidWakeNotification` ·
  `sessionDidBecomeActiveNotification` · `sessionDidResignActiveNotification`
- Apple Technote: "Caffeinate" pattern (mostly CLI but docs the
  assertion model our `StayAwakeService` already uses)
- System notifications are posted on
  **`NSWorkspace.shared.notificationCenter`**, *not*
  `NotificationCenter.default`. Forgetting this is the #1 reason
  observers silently never fire.

**Known gotchas:**
- `willSleepNotification` fires before actual sleep, but there is no
  guarantee about how long you have. Target: finish work in <100ms.
- `didWakeNotification` fires after wake, but **Power Nap** wakes
  (macOS waking briefly for scheduled background work) also fire it.
  The machine may re-sleep shortly after. Don't trigger expensive
  re-initialization greedily on every didWake.
- Lid close ≠ sleep. If an external display is connected, closing
  the lid does not sleep the machine; only the internal display
  sleeps. Differentiate via `screensDidSleepNotification` vs
  `willSleepNotification`.
- The `willSleep`/`didWake` pair is not perfectly symmetric. A
  forced sleep (power button) may skip `willSleep` entirely. Build
  the recovery path assuming you might wake up without knowing you
  slept.

---

## 4. libproc process enumeration + inspection

Used throughout `ProcessInspector`. Low-level but well-documented;
this entry exists to save the next person from re-reading the
headers.

**Canonical sources:**
- `/usr/include/libproc.h` — public API
- `/usr/include/sys/proc_info.h` — flavor constants + info struct
  definitions (`proc_taskinfo`, `proc_bsdinfo`, etc.)
- Functions: `proc_listpids`, `proc_pidinfo` (with flavor),
  `proc_pidpath`, `proc_name`, `proc_regionfilename`
- Sample usage: Darwin-XNU source, `tools/tests/libMicro/` and the
  `ps` command source (`top-level adv_cmds / ps.tproj`)

**Known gotchas:**
- `proc_pidinfo` returns the number of bytes filled on success; test
  against the expected struct size, not just `> 0`.
- `pbi_comm` (in `proc_bsdinfo`) is truncated to 16 bytes
  (MAXCOMLEN+1). For the full name, use `proc_name` or
  `proc_pidpath` + basename. We tolerate the 16-byte truncation in
  `ProcessInspector` because it's good enough for display.
- Processes can die mid-call; `proc_pidinfo` returns 0 and sets
  errno to ESRCH. Our code treats this as "skip this pid this tick"
  and moves on.
- CPU time in `proc_taskinfo` is cumulative nanoseconds. Instant
  CPU% is computed by deltas against the previous sample (see
  `ProcessInspector.snapshot`). Never report CPU% from a single
  sample — it's nonsense.
- `proc_listpids(PROC_ALL_PIDS, ...)` returns *all* pids including
  zombies and processes owned by other users. Filter by
  `pbi_uid == getuid()` for user-owned only; we never throttle
  non-user processes.

---

## Adding new entries

When we start depending on a new system-level API whose behavior
isn't obvious from Swift docs alone, add an entry here before
merging the feature. Keep the three-section shape:

1. What it is / where we use it
2. Canonical sources (manpage, Apple doc page, header file, WWDC
   session)
3. Known gotchas (the things that would bite a reader who didn't
   know)

Planned future entries (not yet needed):

- AppIntents + Shortcuts.app integration (when we land #54)
- INFocusFilter for Focus Filter integration (when we land #55)
- Global hotkey APIs: `NSEvent` monitors vs. Carbon `RegisterEventHotKey`
  vs. `EventTap` (when we land #56)
- IOKit HID sensor access details (currently in README Sandboxing
  section; may promote to a full entry if we ever debug sensor
  discovery edge cases)
