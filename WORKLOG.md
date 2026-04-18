# AirAssist — Autonomous Build Worklog

Started: 2026-04-17 ~20:37
Baseline commit: `10a6427` (TG Pro parity)

## Goal (from `air_assist_next_phase_brief.md`)

Expand AirAssist from a thermal monitor into a thermal + CPU-usage management
tool. Three independently-toggleable capability buckets:

1. **Temperature monitoring & control** — already done (TG Pro parity)
2. **Per-app CPU limiting** (AppTamer-style) — NEW
3. **System-wide caps** on max temp and/or max CPU usage — NEW

## Architecture decisions

### Throttling mechanism: SIGSTOP/SIGCONT duty cycling

Public macOS APIs on modern Apple Silicon (macOS 15+/26) don't permit direct
CPU frequency control, Turbo Boost disable, or MSR access without deprecated
kernel extensions. AppTamer itself uses SIGSTOP/SIGCONT cycling; this is what
we'll use too.

- **How it works**: send `SIGSTOP` to pause the target process for
  `(1 - duty) × period` milliseconds, then `SIGCONT` to resume for
  `duty × period`. Cycle continuously. Target CPU% ≈ duty × (original
  demand). Typical cycle: 100 ms period.
- **Permissions**: works on user-owned processes with zero entitlements.
  System daemons (launchd, kernel_task, WindowServer, etc.) require root
  and are never acceptable targets anyway.
- **Safety**: always release with `SIGCONT` on exit. Maintain a hardcoded
  exclude list of system-critical processes so the user can't wedge their
  machine. Include our own PID, Claude Code, Xcode, Finder, WindowServer,
  etc.

### Governor (bucket #3): hysteresis over max-temp and max-CPU caps

- User sets: `maxTempC` (e.g. 85°C), `maxCPUPercent` (e.g. 300% = ~3 cores),
  `governorMode` (off / temp / cpu / both).
- Every `N` seconds (2s feels right — matches reasonable thermal response):
  - Sample temp and CPU.
  - If either exceeds its cap: find top CPU consumers in the user's
    non-excluded process list. Apply duty-cycle throttling starting at
    85% and stepping down (70%, 55%, 40%) if the breach continues.
  - If both are below cap − hysteresis (5°C / 50%): step duty back up.
- Per-app rules (bucket #2) are layered on top: an app can have a hard
  cap (e.g. "Backblaze never above 50%") applied regardless of governor.
- Adaptive (PID) control is a v3 enhancement. Starting with hysteresis.

### Excluded processes (never throttle)

`kernel_task`, `launchd`, `WindowServer`, `coreaudiod`, `hidd`,
`ControlCenter`, `SystemUIServer`, `Dock`, `Finder`, `loginwindow`,
`backboardd`, `runningboardd`, `Xcode`, our own PID, Claude Code if we
can detect it, any process named `AirAssist`.

## Implementation plan (ordered)

1. [ ] `ProcessInspector` — enumerate processes with CPU% via `proc_listpids`
       + `proc_pidinfo(PROC_PIDTASKINFO)`; delta over time gives percent.
2. [ ] `ProcessThrottler` — actor that manages per-PID SIGSTOP/SIGCONT cycles.
3. [ ] `ThrottleRule`, `ThrottleRulesPersistence` — per-app persistent caps.
4. [ ] `GovernorConfig` + `ThermalGovernor` — glue: reads temp/CPU, enforces
       caps, layers on top of per-app rules.
5. [ ] UI: new Preferences tabs (CPU rules, Governor).
6. [ ] Dashboard: show currently-throttled processes + live CPU%.
7. [ ] Integration into `ThermalStore` + `AppDelegate` lifecycle.
8. [ ] Safety: exclude list, teardown on exit, no-op if throttling disabled.
9. [ ] Build + smoke test (spawn `yes > /dev/null`, verify it gets throttled).
10. [ ] Release-build memory check.

## Progress

(updated as we go)

---

## Phase 2 complete — 2026-04-17

Delivered:
- `ProcessInspector` — libproc-based enumeration, delta CPU%, bundle-id resolution.
- `ProcessThrottler` — SIGSTOP/SIGCONT duty cycler, 100ms period, safe teardown.
- `ThermalGovernor` — 1Hz hysteresis loop over temp cap + total-CPU cap.
- `ThrottleRuleEngine` — applies user-defined per-app rules each tick.
- Persisted `ThrottleRulesConfig` / `GovernorConfig` via UserDefaults.
- New Preferences tabs: **App Rules** and **Governor**.
- Dashboard panel showing live throttled processes.
- Safe exit: `ThermalStore.stop()` SIGCONTs everything before termination.

Smoke tests:
- Raw SIGSTOP/SIGCONT works on `yes` (98% → 0% → 98%).
- End-to-end with Release build + pre-seeded rule at 30% duty: `yes` settled
  at ~30-33% CPU (matches configured duty).
- Release binary RSS ~46MB at startup.

Commits:
- `10a6427` baseline (phase 1 + prior menu-bar work)
- `660a2a9` per-app throttling + governor
