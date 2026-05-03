# Visibility — Build Plan

Internal name for the v0.14.0 sprint. Four pieces, all on the
`visibility` branch:

1. **CPU Activity panel** inside the popover (live top processes,
   click-to-act)
2. **Popover section model** — data layer for which sections appear
3. **Historical CPU offenders** — 7-day rolling aggregation
4. **Slot metric architecture** — menu bar can show CPU %, memory
   pressure, battery %, in addition to existing temperatures
5. **Popover customization UI** — toggle which sections appear

(Phases 2 and 5 are conceptually paired but split because Phase 2
is just the data layer and Phase 5 is the UI on top of it.)

## Companion documents

- `NON_AIR_ROADMAP.md` — chassis-adaptive UI (not directly used here
  but relevant when slot metrics need to know what hardware exists)
- `CHANGELOG.md` `[Unreleased]` — accumulates per-phase entries
- `References/` (gitignored, local-only) — research material on
  reference monitoring apps

---

## Hard constraints

These are settled — don't relitigate without surfacing the
conversation:

1. **Apple Silicon only.** Existing project rule.
2. **Free + open source.** No license tier, no gating.
3. **No new privileged helper.** Everything in this sprint runs in
   the existing app's userspace permissions. No new entitlements.
4. **No intermediate version releases.** Each phase commits +
   accumulates `[Unreleased]` CHANGELOG entries. No `v*.*.*` tag
   pushes until the full sprint is done. v0.13.0 stays as the latest
   public release the entire build period.
5. **Single-brand framing.** All new UI lives under existing
   AirAssist surfaces. No "Visibility" branding visible to the user
   — that's just the internal sprint name.

---

## Architecture overview

This sprint is mostly **surfacing existing data** — the foundation
is already in place.

### What we already have (reused, not rebuilt)

- **`ProcessInspector`** — top CPU processes via `proc_*` syscalls
- **`ProcessSnapshotPublisher`** — already publishes snapshots at 1Hz
  on the control loop
- **`ThermalGovernor.lastTopProcesses`** — current snapshot, already
  `@Observable`
- **`ThrottleEventLog`** (NDJSON) and **`ThrottleActivityLog`**
  (in-memory) — throttle history
- **`ThrottleSummary` aggregator** — pattern for rolling-window
  rollups (the existing weekly throttle summary)
- **`ProcessThrottler`** — duty-cap mechanism for the Throttle action
- **`NeverThrottleList`** — allowlist for the Never-Throttle action
- **Existing context menu pattern** on manual throttle rows in the
  popover (Show in Activity Monitor, Copy name, etc.)

### What's new

- **`CPUActivityLog`** (Phase 3) — sparse process-keyed NDJSON, 60s
  sampling, 7-day prune. New shape but mirrors `ThrottleEventLog`'s
  pattern.
- **`PopoverSection` enum + ordering model** (Phase 2) — backend
  data type with stable IDs and persisted visibility/order.
- **`SlotMetric` abstraction** (Phase 4) — refactor of the slot
  system to support non-temperature metrics. Touches
  `MenuBarController`, `MenuBarIconRenderer`, `DisplayPrefsView`.

---

## Naming rules

Same as always: brand stays as **Air Assist** to users. "Visibility"
is internal-only. New UI strings:

| ✅ Use this | ❌ Don't use this |
|---|---|
| "CPU Activity" (section header) | "Visibility panel" |
| "Top processes" | "Process Inspector" |
| "Customize popover" / "Show in popover" | "Visibility settings" |
| "Top CPU consumers — this week" (dashboard) | "Habitual offenders" |

---

## Phase breakdown

Each phase is its own PR into `visibility`. Each adds one bullet
under `[Unreleased]` in `CHANGELOG.md`. No version tags until done.

### Phase 1 — CPU Activity panel

New section inside `MenuBarPopoverView`, expanded by default,
showing top 5 CPU processes from `governor.lastTopProcesses`.

- Section header: "CPU Activity" with `cpu` SF Symbol
- 5 rows: process display name + CPU% + tappable
- Right-click (or hover-revealed action button) per row:
  - **Throttle this app** — applies one-off duty cap (uses existing
    `ProcessThrottler` path)
  - **Add throttle rule** — opens `AddRuleSheet` pre-filled
  - **Add to never-throttle** — calls `NeverThrottleList.add`
  - **Show in Activity Monitor** — existing context action
- 1Hz refresh tied to existing governor tick (free, no new polling)
- Skip rule-managed PIDs to avoid duplication (governor already
  excludes these from `lastTopProcesses`)
- Empty state: "Nothing notable. Your Mac is idle."
- Tests: section renders, top-N selection, action dispatch

### Phase 2 — Popover section model

Data layer only — no user-facing prefs UI in this phase.

- New `PopoverSection` enum with stable string IDs:
  `sparkline`, `sensorGrid`, `cpuActivity`, `frontmostThrottle`,
  `manualThrottles`, `quickThrottles`, `stayAwake`, `scenarios`,
  `pauseSubmenu`, etc. — one per existing top-level section.
- `@AppStorage("popover.sections.order")` — JSON-encoded
  `[PopoverSection]` array. Default: full set in current order.
- `@AppStorage("popover.sections.hidden")` — `Set<PopoverSection>`
  of disabled IDs. Default: empty (everything visible).
- `MenuBarPopoverView` refactored to iterate the order array and
  conditionally render each section.
- **No UI change** for users in this phase — defaults match current
  behavior. Phase 5 adds the prefs to manage these.

### Phase 3 — Historical CPU offenders

- New `CPUActivityLog` (NDJSON, on-disk) — pattern lifted from
  `ThrottleEventLog`. Stores process-keyed samples:
  `{ts, pid, bundleID, name, cpuPercent}`.
- Sampling cadence: **60 seconds**. Driven by a long-running
  `Task` on the existing control loop.
- Pruning: rolling 7 days, run on every launch + once daily.
- New `CPUActivitySummary` aggregator — bucket samples by bundleID,
  output sorted top-N by cumulative CPU-seconds above a threshold
  (default 10% — counts as "actively running, not idle").
- New `CPUConsumersView` panel on the dashboard, alongside the
  weekly throttle summary. Layout: process row with name + total
  active time + share-of-window.
- Tests: aggregation correctness, edge cases (process spans window
  boundary, identical bundle IDs across many PIDs).

### Phase 4 — Slot metric architecture

The big refactor. Extends the menu bar slot system to support
non-temperature metrics.

- New `SlotMetric` enum:
  - `.temperature(SensorRef)` — existing path
  - `.cpuTotal` — total system CPU %
  - `.memoryPressure` — three-state OS-level pressure
  - `.batteryPercent` — battery charge %
- `MenuBarIconRenderer` extended:
  - Generic `MetricValue` wrapper carrying value + unit + color tier
  - Per-metric formatter (`°`, `%`, no-unit)
  - Per-metric color thresholds (hard-coded for v1):
    - CPU: warm 60%, hot 85%
    - Memory: follow OS state (Normal / Warning / Critical → green /
      orange / red)
    - Battery: warm 30%, hot 15% (inverted — low is bad)
- `DisplayPrefsView` slot picker becomes two-level:
  - First picker: Metric type (Temperature / CPU / Memory / Battery)
  - Second picker: Sub-option (e.g., for Temperature: Highest /
    Average / Individual; for CPU: Total / per-core)
- Trend arrow + source badge logic generalized — works across
  metric types.
- `MenuBarController` reads new metric values from existing data
  sources:
  - CPU: `governor.lastTotalCPUPercent` (already published)
  - Memory: `kern.memorystatus_vm_pressure_level` sysctl (new tiny
    accessor)
  - Battery: existing battery telemetry path
- Tests: per-metric formatting, threshold transitions, trend across
  units.

### Phase 5 — Popover customization UI

- New "Popover" section in Preferences (or extend existing
  "Menu Bar" pane — decide during impl)
- Visibility toggles for each `PopoverSection`
- **No drag-to-reorder in v1.** Order is fixed in code; only
  visibility toggles are user-controllable. The data model from
  Phase 2 already supports ordering, so adding drag-handles in a
  follow-up is localized.
- Help text per row explaining what each section shows
- Backed by the `@AppStorage` from Phase 2

> **End of v0.14.0 sprint.** Tag, release, ship.

---

## CHANGELOG protocol

Same as always:

- Each phase PR adds **one bullet** under `[Unreleased]` in
  `CHANGELOG.md`, in the appropriate section
- At tag time:
  1. Rename `[Unreleased]` → `[0.14.0] — YYYY-MM-DD`
  2. Add a fresh empty `[Unreleased]` above it
  3. Add a new `WhatsNewSheet` entry with curated bullets
  4. Bump version in `project.yml` / `Info.plist` /
     `AirAssistCLI/main.swift`
  5. Update the live homebrew tap cask URL extension
     (`.zip` → `.dmg`) one-time
  6. Tag and push; workflow handles the rest

---

## Open questions per phase

| Question | Blocks phase |
|---|---|
| Empty-state copy: "Your Mac is idle" vs "All processes ≤ N% CPU" | Phase 1 |
| Section header iconography (`cpu` symbol vs custom) | Phase 1 |
| `CPUActivityLog` size budget — what to do if NDJSON > 10 MB | Phase 3 |
| Memory pressure read API stability — sysctl vs `os_proc` API | Phase 4 |
| Drag-to-reorder follow-up timing — same release with toggle, or post-v0.14.0 | Phase 5 |

None of these block starting work. Each is decided when its phase
opens.

---

## Risk register

In rough probability order:

1. **Slot metric refactor (Phase 4) is invasive.** Touches the
   renderer, the controller, the prefs, the trend logic, the
   accessibility labels, and the tests for all of those. Plan for
   the PR being big and the test diff being larger than the code
   diff.
2. **Memory pressure threshold mapping is fuzzy.** macOS reports a
   three-state value, not a percentage. Need to map cleanly to our
   color scheme without inventing thresholds that aren't
   meaningful.
3. **CPUActivityLog disk growth on busy systems.** A user running
   many distinct hot processes for days could grow the log faster
   than expected. Mitigation: compaction at write time (drop
   samples below 5% CPU, since those don't matter for "habitual
   offender" rollup).
4. **Popover section ordering migration.** If we ever add a new
   section in a follow-up release, existing users' persisted order
   array won't include it. Need a "merge in any unknown sections"
   step on load. Cheap to implement; just needs to be remembered.

---

## Cross-references

- `NON_AIR_ROADMAP.md` — referenced when Phase 4 needs to know
  about hardware capabilities
- `CHANGELOG.md` — `[Unreleased]` accumulator
- `.github/workflows/release.yml` — DMG build pipeline
- `.github/workflows/homebrew-tap-bump.yml` — auto-bump on publish
