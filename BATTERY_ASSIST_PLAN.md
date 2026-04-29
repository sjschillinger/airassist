# Battery Assist — Build Plan

Internal codename for the battery-management feature shipping on the
`battery-assist` branch. **The user-visible product stays as Air
Assist** — there is no separate "Battery Assist" sub-brand, no
distinct UI surface, no second app icon. Battery features are
*chapters of Air Assist*, not a separate thing.

This is the working build document. It distills external research
and a private recreation spec into the specific architecture we're
adding on top of AirAssist's existing codebase.

## Companion documents

- `NON_AIR_ROADMAP.md` — chassis-adaptive UI (`HardwareProfileResolver`)
- `Signing.xcconfig.template` — local signing config for the helper
- `CHANGELOG.md` `[Unreleased]` — accumulates per-phase entries
- `References/` (gitignored, local-only) — research material including
  the recreation spec we're drawing patterns from

---

## Hard constraints

These are settled. Don't relitigate without surfacing the conversation:

1. **Apple Silicon only.** M1–M5. Intel paths in any reference material
   are documented for context but never scoped.
2. **Free + open source.** No license module, no Pro tier, no feature
   gating, no online activation, no analytics upload queue. Everything
   ships free.
3. **Single brand.** Air Assist with battery features added — not a
   separate product. "Battery Assist" is internal-only naming for this
   sprint; it never appears in user-visible copy.
4. **No intermediate version releases.** Increments commit and PR
   *within* `battery-assist`, with one `[Unreleased]` CHANGELOG entry
   per phase. **No `v*.*.*` tags pushed until the full sprint
   completes** — v0.13.0 stays as the latest public release the entire
   build period.
5. **Develop locally first; pay $99 at the end.** Free Apple
   Development cert covers all local testing of the privileged helper.
   Paid Developer ID + notarization happens once everything is
   validated and ready to ship publicly.
6. **Single privileged helper for all hardware writes.** Future fan
   control (deferred) will share the same helper. Do not ship two
   daemons.

---

## Architecture

Three processes, two of them already exist:

1. **`AirAssist`** (existing main app)
   - Owns state, policy, UI, persistence, scenarios.
   - Talks to the new helper over XPC for anything requiring root.
2. **`AirAssistBatteryHelper`** (new privileged daemon)
   - Registered via **`SMAppService.daemon(plistName:)`** — explicitly
     not the deprecated `SMJobBless`.
   - Plist at `Contents/Library/LaunchDaemons/com.sjschillinger.airassist.battery-helper.plist`.
   - Single responsibility: validated SMC reads/writes and privileged
     IOKit / power-management operations behind a
     code-signing-pinned XPC interface.
3. **`AirAssistRescue`** (existing tiny CLI, unchanged)
   - Continues handling SIGCONT recovery for the throttler. Battery
     work does not extend it.

### Persistence

- **`UserDefaults`** — settings and compact state (existing pattern,
  unchanged).
- **NDJSON** — throttle event log (existing pattern, unchanged).
- **SQLite** — new, for battery telemetry time-series only. Located at
  `~/Library/Application Support/AirAssist/battery.sqlite3`. Schema
  details under "Phase 6" below.

### Naming rules in code vs UI

Internal (commits, code symbols, docs, branch names): **Battery Assist**
is fine. Symbols like `BatteryHelperClient`, `ChargePolicyEngine`,
identifiers like `com.sjschillinger.airassist.battery-helper` —
all OK, none of these are user-visible.

User-visible (UI strings, README, release notes, LinkedIn copy):

| ✅ Use this | ❌ Don't use this |
|---|---|
| "Battery" (Preferences section title) | "Battery Assist" |
| "Set a charge limit" | "Configure Battery Assist" |
| "Battery health" | "Battery Assist health view" |
| "Install the battery helper" | "Install Battery Assist" |
| "Air Assist now manages battery health too" | "Battery Assist is a new app" |

---

## What we're keeping from the recreation spec

Verbatim concepts, with our architecture substituted:

- **Charge limit** with a state engine
  (`charging` / `paused` / `sailing`)
- **Sailing mode** with range thresholds (not single value)
- **Heat protection** with hysteresis (extended to multi-sensor — see
  Differentiators)
- **Calibration assistant** with multi-stage state persistence
- **Sleep coordination** (extending `StayAwakeService`)
- **Scheduling** for time-based charge rules
- **Telemetry collection** at the spec's polling cadence
- **Dashboard widgets** for battery health, electrical specs, time
  remaining
- **Helper install / uninstall** flow with status indicator and
  actionable error surfacing
- **Debug bundle export** (extending the existing `DiagnosticBundle`)

## What we're dropping

Documented so we don't backslide:

- **License module** — no Pro tier, no activation, no online
  verification. Everything ships free.
- **Intel paths** — `intelMode` charge state, Intel SMC fallback,
  `intelLegacy` profile.
- **Parallel app shell** — we extend `MenuBarController`,
  `ThermalStore`, `OnboardingWindow`, `MenuBarPopoverView`,
  `PreferencesView`, etc., rather than building parallel structures.
- **Parallel onboarding manager** — extend the existing
  `OnboardingWindow` flow with a "Want battery management? Install
  the helper" step.
- **Analytics upload queue** — no third-party telemetry.
- **MagSafe LED control** — deferred to a later release. Out of
  v0.14.0 scope.
- **Forcing fans to spin** — fan control is its own future feature
  (out of v0.14.0 scope by explicit user direction).

---

## Differentiators

Air-Assist-specific capabilities that don't exist in the reference
because the reference doesn't have our surrounding context:

1. **Multi-sensor heat protection.** The reference watches battery
   temp only. We already monitor SoC, CPU, GPU, ambient. The new
   `HeatProtectionManager` accepts any relevant sensor crossing its
   threshold — and (optionally) throttles the offending process at
   the same time, since we already have a process throttler.
2. **Scenario integration.** `ScenarioPreset` grows a `BatteryProfile`
   field. Each one-click scenario bundles governor + thermal + battery
   together:
   - **Lap / Cool** → 80% cap, multi-sensor heat-pause threshold
     lowered, charging-temp watched
   - **Presenting** → 100% (you need range)
   - **Performance** → no cap, pause-on-hot for the battery only
   - **Auto** → balanced default
3. **Workload-aware override.** Sustained-CPU detection (already built
   for the governor) can temporarily raise the cap mid-build so a
   long compile or render isn't killed by hitting the cap exactly when
   the work is at its peak.
4. **Unified Shortcuts + CLI.** New battery commands extend the
   existing `airassist://` URL scheme and the `airassist` CLI. No new
   automation surface; the same code path that already drives Pause /
   Resume / Throttle handles battery commands too.
5. **Single menu-bar surface.** All battery state lives in the
   existing dropdown — one icon, one popover, one Preferences window.

---

## Phase breakdown

Each phase is its own PR into `battery-assist` (not main). Each phase
adds one bullet under `[Unreleased]` in CHANGELOG.md. No version tags
during the sprint.

### Phase 1 — Helper foundation
- New `AirAssistBatteryHelper` target in `project.yml`
- Hardened runtime, signing config sourced from `Signing.xcconfig`
- LaunchDaemon plist at the canonical path
- Builds clean, ad-hoc signed locally, registers and unregisters via
  `SMAppService.daemon`
- Smoke test: helper appears in System Settings → Login Items
- **No XPC yet** — registration round-trip only

**Deliverable:** empty helper target that registers and unregisters
cleanly on the developer's own Mac.

### Phase 2 — XPC contract + ping-pong
- `BatteryHelperProtocol.swift` shared between targets
- `BatteryHelperClient` wrapper in the app
- Code-signing-requirement-pinned in both directions
- One method: `ping(reply:)`, helper returns its version string
- Tests: connection lifecycle, version-mismatch handling, helper
  unavailable

### Phase 3 — Helper install / uninstall flow in Preferences
- New "Battery" section in Preferences (always visible)
- Empty state with "Install helper to enable" CTA
- Status indicator: registered / not registered / requires approval /
  version mismatch
- Surfaces XPC errors as actionable alerts (mirrors the existing
  `LaunchAtLoginService` UX)

### Phase 4 — `HardwareProfileResolver`
- Per `NON_AIR_ROADMAP.md` Tier 1 spec
- Detect chassis class via `hw.model`
- Capability flags injected into `ThermalStore`
- Used by both Battery Assist and any future hardware-touching feature

### Phase 5 — `BatteryTelemetryService` (read-only)
- Helper-side reads for: battery %, hardware %, temperature,
  voltage / current / power, cycle count, condition, time remaining,
  power source, adapter metadata
- Polling cadence: 5s background, 1s with popover open
- Published via `@Observable`, consumed by UI
- **No writes yet** — read-only validates the entire IPC chain

### Phase 6 — SQLite skeleton
- Schema: `telemetry_samples`, `battery_health_snapshots`
- Migration system from day one
- 30-day rolling-window pruning (user-configurable)
- Added to `DiagnosticBundle` export

### Phase 7 — Read-only dashboard widgets
- Battery health card (cycles, condition, capacity vs design)
- Electrical specs card (V / A / W in / out)
- Power adapter card
- Time remaining / time to full
- All driven by `BatteryTelemetryService` — no charge-write
  dependency

> **End of read-only foundation.** At this point the helper is fully
> validated end-to-end with zero charge-control behavior. Safe to keep
> iterating without risk to anyone's battery.

### Phase 8 — Charge limit MVP
- `ChargePolicyEngine` — state machine with `charging` / `paused`
- SMC writes via helper
- Slider in Preferences and popover
- Status display in popover
- **First write-capable phase.** SMC research must be complete before
  this phase opens.

### Phase 9 — Sailing mode + heat protection (single-sensor)
- `SailingManager` — range thresholds with hysteresis (e.g. 75-80%)
- `HeatProtectionManager` — battery-temp-only first
- Both reuse `ChargePolicyEngine`'s state machine

### Phase 10 — Sleep coordination
- Extend `StayAwakeService` patterns into a battery-aware coordinator
- "Don't charge while sleeping" / "Disable sleep until limit reached"
- Power-assertion lifecycle through the helper

### Phase 11 — Scenario integration
- Add `BatteryProfile?` to `ScenarioPreset`
- Each scenario applies governor + thermal + battery on one click
- Extend `ScenarioPresetTests` to pin the new values per scenario

### Phase 12 — Multi-sensor heat protection
- `HeatProtectionManager` accepts any sensor crossing threshold
- Optional: throttle the offending process simultaneously to cool
  faster (the AlDente-can't-do-this differentiator)

### Phase 13 — Workload-aware override
- Detect sustained CPU work via existing governor signals
- Temporarily raise cap during qualifying long-running jobs
- Conservative defaults; release on workload completion

> **End of v0.14.0 sprint.** Tag, release, ship.

Calibration assistant, scheduling UI, MagSafe LED control → v0.15.0+.

---

## CHANGELOG protocol

Each phase PR adds **one bullet** under `[Unreleased]` in CHANGELOG.md,
in the appropriate `### Added` / `### Changed` / `### Improved` /
`### Fixed` section. By the time we tag, the section reads like a
real release-notes draft.

At tag time (single coordinated commit on `battery-assist` →  PR to main):
1. Rename `[Unreleased]` to `[0.14.0] — YYYY-MM-DD`
2. Add a fresh empty `[Unreleased]` above it
3. Add a new `WhatsNewSheet` entry with a curated subset of bullets
4. Bump version in `project.yml` / `Info.plist` / `AirAssistCLI/main.swift`
5. Update the live homebrew tap cask URL extension (.zip → .dmg)
   one-time
6. Tag and push; workflow handles the rest

---

## Open questions to resolve before they block a phase

None of these block starting work; each blocks a specific phase.

| Open question | Blocks phase |
|---|---|
| Apple Silicon SMC keys for charge limit (M1–M5) | Phase 8 |
| `pmset` interaction with macOS "Optimized Battery Charging" | Phase 8 |
| Helper crash recovery: SMC state persistence on daemon exit | Phase 8 |
| Discharge-over-limit feasibility on Apple Silicon | Post-v0.14.0 |
| Notarization quirks for daemons | Phase A → B transition (paid tier) |
| Free Apple Development cert: SMAppService.daemon registration on dev's own Mac | Phase 1 |

---

## Risk register

In rough probability order:

1. **SMC keys differ across M-series generations.** Multiple compat
   revs likely needed. Phase-1-through-7 work doesn't depend on the
   key set; we can defer SMC research until Phase 8 opens.
2. **macOS "Optimized Battery Charging" interaction.** May fight our
   cap. Test plan: validate our cap holds with OBC on; if it doesn't,
   either disable OBC silently or expose a user warning.
3. **Helper crash recovery.** What happens to SMC state if the daemon
   dies mid-charge? Designed-in answer: cap is reset to "no limit" on
   daemon exit (fail-safe). Verified by Phase 8 testing.
4. **Notarization rejection.** Helpers face higher scrutiny. Cost on
   failure is iteration time, not money.
5. **A user's battery genuinely fails after using our cap.** Unlikely
   but real. Mitigations:
   - Conservative defaults (cap at 80%, never below 50%)
   - SAFETY.md gets a Battery Assist section
   - LICENSE keeps "AS IS" prominent
   - All charge-control behavior gated behind explicit user opt-in
     after helper install

---

## Cross-references

- `NON_AIR_ROADMAP.md` — `HardwareProfile` foundation (Phase 4)
- `Signing.xcconfig.template` — local + paid signing config
- `References/` (gitignored) — recreation spec and research material
- `CHANGELOG.md` — `[Unreleased]` accumulator
- `.github/workflows/release.yml` — DMG build pipeline (already
  DMG-aware)
- `.github/workflows/homebrew-tap-bump.yml` — auto-bump on publish
- `SAFETY.md` — gets a Battery Assist section in Phase 8
