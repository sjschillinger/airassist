# AirAssist Safety Invariants

AirAssist throttles running processes by duty-cycling `SIGSTOP`/`SIGCONT`.
That is a powerful primitive. This document enumerates the invariants the
codebase must preserve so the app can never:

1. Override Apple's own thermal management (architecturally impossible — we
   have no kernel access — but still worth stating).
2. Leave a user-owned process paused after AirAssist itself dies, panics, or
   is SIGKILL'd.
3. Throttle its own PID, its parent shell/launcher, or system-critical
   processes.
4. Damage hardware. (Hardware damage requires writing to hardware. We don't.)

## Why hardware damage is not possible

- Sensor access is **read-only** via `IOHIDEventSystemClient`. No sensor,
  fan, or firmware state is written.
- Process control is via the public `kill(2)` system call with `SIGSTOP`
  and `SIGCONT`. There is no way to use these to modify firmware, disable
  kernel thermal management, or override the SMC's thermal-trip behaviour.
- AirAssist ships as a sandboxed user-space app. It has no kernel extension,
  no entitlements for hardware control, and no IOKit user clients for
  anything writable.

Apple Silicon's thermal management lives in the kernel and in SMC firmware,
both of which sit below anything a user-space process can reach. AirAssist
can only influence how fast user processes consume CPU — Apple still gets
the final word on throttling, sleep, and shutdown.

## Defence-in-depth

The following defences are layered so that any single failure (crash, bug,
corrupted config) cannot leave the system in a bad state.

### 1. Dead-man's-switch file — `SafetyCoordinator.writeInflight`

Every mutation of the throttler's in-flight PID set rewrites
`~/Library/Application Support/AirAssist/inflight.json`. On **every** launch,
before any other subsystem starts, `SafetyCoordinator.recoverOnLaunch()`
reads that file and sends `SIGCONT` to every PID listed — then deletes it.

This covers: crashes, `kill -9`, power loss, kernel panic, reboot while
paused.

### 2. Signal handlers — `SafetyCoordinator.installSignalHandlers`

We install `sigaction(2)` handlers for `SIGTERM`, `SIGINT`, `SIGHUP`, and
`SIGQUIT`. Each handler synchronously `kill(pid, SIGCONT)`s every in-flight
PID from a C array (signal-safe: no locks, no allocation), then reinstalls
`SIG_DFL` and re-raises so normal termination proceeds.

### 3. Watchdog — `SafetyCoordinator.startWatchdog`

A 4Hz main-actor task checks how long each PID has been continuously
SIGSTOPed. Anything stopped longer than `watchdogMaxPauseMs` (default 500ms)
is force-continued. The cycler will simply stop it again on the next cycle
if the rule still applies. This bounds any bug in the cycler's timing.

### 4. Own-process-tree protection — `SafetyCoordinator.isAncestorOrSelf`

`ProcessThrottler.setDuty` refuses to throttle its own PID or any PID in
our parent chain (walking `pbi_ppid` back to `launchd`). This catches the
footgun of a user accidentally creating a rule matching their shell,
terminal, or login session.

### 5. Config sanity clamps — `GovernorConfigPersistence.sanitize`

Every load of `GovernorConfig` and `ThrottleRulesConfig` clamps values to
the ranges the UI enforces:

| Field                  | Range         |
| ---------------------- | ------------- |
| `maxTempC`             | 40 – 100 °C   |
| `maxCPUPercent`        | 50 – 1600     |
| `tempHysteresisC`      | 1 – 30        |
| `cpuHysteresisPercent` | 5 – 400       |
| `maxTargets`           | 1 – 10        |
| `minCPUForTargeting`   | 5 – 100       |
| rule `duty`            | 0.05 – 1.0    |

A hand-edited plist cannot push the governor into either "never intervenes"
or "throttle everything to a halt" territory.

### 6. Excluded-name list — `ProcessInspector.excludedNames`

System daemons, WindowServer, Finder, loginwindow, AirAssist itself, common
terminals, Claude Code, Xcode — names that would produce a bricked UX if
paused — are refused at the throttler layer regardless of any rule.

## Ceiling on `maxTempC`

The UI slider caps at **100 °C**. Apple Silicon begins its own thermal
management in the mid-90s °C. Allowing the user to set AirAssist's own cap
above that range would be meaningless (macOS has already taken over) and
invites confusion about what is doing the throttling, so we just disallow
it. The migration in `sanitize()` clamps any pre-existing stored value down
to 100.

## Invariants for future changes

If you add a new entry point that can stop a process (anything that sends
`SIGSTOP`):

- Route it through `ProcessThrottler.setDuty` — do not `kill(SIGSTOP)`
  directly. `setDuty` enforces the ancestor/self check and updates the
  dead-man's-switch file.
- Ensure `releaseAll()` is called on every teardown path.
- If you introduce a new teardown signal, add it to
  `installSignalHandlers`.
- Any new persisted config must be clamped in its `load()`.

If you relax the `excludedNames` list, think hard about what happens when
the app in question is frontmost and gets paused mid-event-loop.
