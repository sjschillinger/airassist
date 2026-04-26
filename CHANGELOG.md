# Changelog

All notable changes to Air Assist are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

Dates are in ISO 8601 (YYYY-MM-DD).

## [Unreleased]

---

## [0.12.1] — 2026-04-26

Polish release on the heels of 0.12.0. The CLI gets the rough edges
sanded off, the localization catalog is now populated with the app's
English strings, and a few VoiceOver labels read more naturally.

### Added

- **`scripts/install-cli.sh`.** One-shot installer that copies the
  built `airassist` binary to `~/.local/bin` (or a target dir you
  pass), seeds shell completion in the right spot for your current
  shell (zsh / bash / fish), and warns if the target dir isn't on
  `$PATH`. Builds Debug if no binary is found in DerivedData.
  `--uninstall` reverses everything.
- **Shell completions.** `airassist completions <zsh|bash|fish>`
  emits a completion script for the chosen shell. The install script
  drops it in the conventional path automatically; manual users can
  redirect to wherever their shell expects it.
- **`airassist status --json`.** Machine-readable status output
  (appRunning, appVersion, scenario, batteryAware, onboarding,
  governor) for scripting and dashboards. Default output is still
  the human-readable form.

### Improved

- **Localization catalog populated.** `Localizable.xcstrings` now
  contains 281 extracted English source strings, ready for
  translators. Source language stays English; no other languages
  shipped in this release.
- **Sharper VoiceOver labels in popover and dashboard.** Pause menu
  splits state from action ("Pause throttling" + "Activate to choose
  a pause duration"). Sparkline trend reads as one sentence. Dashboard
  process row says "currently throttled" instead of bare "throttled".
  Decorative popover header glyph is now `accessibilityHidden` since
  the "Air Assist" text already speaks.

---

## [0.12.0] — 2026-04-26

Tooling + plumbing release. No new user-facing features in the menu
bar — instead, this round adds the surfaces missing for power users
and future contributors: a real CLI, sharper VoiceOver coverage, and
the scaffolding to ship localized builds when translations land.

### Added

- **`airassist` command-line tool.** Single-binary CLI that bridges
  to the running app via the existing `airassist://` URL scheme:
  `airassist pause [<duration>]`, `resume`, `throttle <bundle>
  --duty <N> [--duration <D>]`, `release <bundle>`, `scenario
  <name>`, `status`. Status reads persisted preferences via
  CFPreferences, so it works whether the app is currently running or
  not. Built as a sibling product (not bundled in the app); copy it
  to `/usr/local/bin` to put it on `$PATH`.
- **Localization scaffolding.** `Localizable.xcstrings` catalog wired
  into the app target, with `LOCALIZATION_PREFERS_STRING_CATALOGS`
  enabled. Centralised user-visible strings now route through
  `String(localized:comment:)` so Xcode's loc-strings extractor picks
  them up at build time. Catalog ships empty (English-only release);
  populating it is a follow-up open to translators.

### Improved

- **VoiceOver coverage in popover and dashboard.** Source badges,
  manual-throttle release buttons, sensor-card favorites, the
  scenario and Stay-Awake menu triggers, and the popover sparkline
  all now have explicit `accessibilityLabel`s. Throttle and
  manual-throttle rows are combined into single accessibility
  elements with descriptive labels (name + cap percentage + remaining
  time + source).
- **Sensor card status colors meet WCAG AA large-text (3:1).** The
  bare SwiftUI `.green` and `.orange` against `.regularMaterial`
  measured ~2.6:1 in light mode; replaced with darker RGB variants
  that pass on both materials. Resolves a TODO carried over from the
  v1.0 launch checklist.

---

## [0.11.0] — 2026-04-26

Polish + integrations release. The bones from 0.10 stay put; this
round fills in the corners — first-run + What's-New sheets, governor
notifications, a never-throttle list, scenario presets, sensor
favorites, an activity log, Shortcuts.app intents, and a state-aware
menu bar icon.

### Added

- **First-run welcome + "What's new" sheets.** A short onboarding on
  first launch covering what the app does and what permissions to
  expect; on every subsequent version bump, a one-time "What's new"
  sheet summarising the release. Both keyed in UserDefaults so they
  never repeat.
- **Governor notifications (opt-in).** When the governor auto-throttles
  on temperature or CPU, fire a system notification ("Air Assist is
  throttling — \<reason>"). Off by default; toggle in
  Preferences → General. 60-second cooldown to avoid spam during
  oscillation, and only fires on the rising edge of a throttle event.
- **Never-Throttle list.** A user-managed allowlist in
  Preferences → Throttling. Anything on it is exempt from *every*
  throttle source — governor, per-app rules, and even an explicit
  manual click. Stronger than the built-in `excludedNames` (which
  protects only system-critical bundles); intended for "this is mine,
  hands off" cases like a build, a render, or a meeting client.
  Add by picking from running processes or by free-form name entry.
- **Scenario presets.** One-click bundles in the popover and
  Preferences → Throttling: Presenting (governor off, display awake),
  Quiet (aggressive thresholds, both modes, ignores battery), 
  Performance (governor off, display awake), Auto (balanced + 
  battery-only). Persists last-applied scenario across launches.
  Per-app rules are deliberately untouched — different lifecycle.
- **Recent activity panel on the dashboard.** Horizontal strip of the
  last 20 throttle events: kind (apply/release), source 
  (governor/rule/manual), process name, duty. Backed by an in-memory
  ring buffer with coalescing — the 10 Hz reapply tick can't drown it.
  Clear button included.
- **Sensor favorites.** Star icon on every sensor card; pinned sensors
  sort to the top of the dashboard grid regardless of the active sort
  order. Backed by UserDefaults; updates live via
  `UserDefaults.didChangeNotification`.
- **State-aware status item icon.** The menu bar icon's accent dot now
  reflects governor state: red pulse during temperature throttling,
  orange pulse during CPU throttling or any active manual cap, static
  blue when the governor is armed but idle, no dot when fully off or
  paused.
- **"Show in Activity Monitor" + context actions on manual throttles.**
  Right-click any active manual throttle row in the popover for: open
  Activity Monitor, copy process name, or "Add to Never-Throttle list"
  (which also releases the cap).
- **Shortcuts.app integration.** Four intents — Pause, Resume, Throttle
  Frontmost App, Apply Scenario — wired through the existing
  `airassist://` URL scheme so Shortcuts and the URL handler share one
  code path and one test suite. Plus a Focus Filter that can pause or
  resume on Focus mode changes (e.g. pause throttling when "Gaming"
  Focus turns on).
- **Diagnostic bundle export polish.** Bundle now includes the throttle
  activity log (`throttle-activity.json`) and the new preference keys
  (`whatsNew.lastSeenVersion`, `neverThrottleNames`,
  `scenarioPreset.last`, `notifications.governor`,
  `throttleFrontmost.duty`, `throttleFrontmost.durationMinutes`).

### Changed

- Dashboard sort partitions favorites first, then applies the chosen
  sort order within each partition. Pinned sensors always appear above
  unpinned, even under "hottest first" or alphabetical.
- `Performance` scenario no longer fully disables the governor. It now
  applies the **gentle** governor preset — armed with a high heat
  ceiling — so a long render or compile isn't gratuitously paused but
  the Mac still has a thermal safety net before it cooks itself.
  `Presenting` keeps the old "governor fully off" behaviour for demos
  where a surprise pause is unacceptable.

### Fixed

- First-run + What's New sheets no longer block `airassist://` URL
  handling on launch. Previously, `NSAlert.runModal()` ran the runloop
  in `.modalPanel` mode and starved `application(_:open:)` of Apple
  Events — a Shortcut or `open airassist://...` invocation that *triggered*
  a cold launch sat queued behind the modal until the user dismissed.
  Replaced with a non-modal floating window that keeps the runloop
  spinning.
- `ProcessThrottler.clearDuty` no longer logs phantom `.release` events
  in the activity log. Previously, calling `clearDuty` with a source
  that wasn't actually a requester (e.g. a `.manual` rejection from
  the never-throttle list when only `.governor` held the PID) would
  still log a release for that absent source.

---

## [0.10.0] — 2026-04-26

Popover-level quick controls. Everything that previously required a
right-click, a Preferences trip, or both is now one click away from
the menu bar icon.

### Added

- **Stay Awake quick picker in the popover.** Off / system-only /
  system + display / display-on-N-min-then-system, with a ✓ on the
  current mode and a live countdown when the timeout variant is
  running. Mirrors the right-click submenu so single-click users
  reach it too.
- **Governor master toggle in the popover.** One-click on/off; turning
  off remembers the prior mode (`temperature` / `cpu` / `both`) and
  restores it on the next on, so flipping the governor never silently
  downgrades a tuned configuration.
- **"On battery only" toggle inline.** Same flag that lives in
  Preferences → Throttling, surfaced next to the master toggle.
  Disabled when the governor itself is off.
- **"Throttle frontmost" button with click-to-release.** Caps whichever
  app you're currently using at the configured duty for the configured
  duration. Click again to release immediately — the row swaps to
  "Release [app]". Refuses to target Air Assist itself. Label reflects
  the captured frontmost app name (snapshotted before the popover
  steals focus, so the button targets the app you were *just* in, not
  Air Assist).
- **Frontmost-app quick throttle preferences.** Preferences →
  Throttling now has a slider (10–85%, 5% steps) and a duration picker
  (15 min / 1 h / 4 h / "Until I clear it") for the popover's quick
  button. Defaults are 30% / 1 hour.
- **"Quick throttles" visibility strip.** When any app is under a
  manual cap, the popover shows a purple strip listing each one with
  the duty %, a live countdown ("47m left"), and an inline ✕ to
  release. Updates once per second while the popover is open.

### Changed

- **Manual throttles bypass the convenience allowlist.** The
  `excludedNames` list (Claude Code, Xcode, Terminal, iTerm2, …)
  protected dev tools from accidental auto-throttle by rules and the
  governor. Manual user clicks are explicit consent, so they now skip
  this gate. The hard safety rails (own-user-only, no-ancestors,
  no-self) still apply to every source.
- **Throttler logs rejected `setDuty` calls.** Each rejection path
  (excluded name, foreign user, ancestor) now emits a single
  `os.Logger` notice with the pid + name. Rate-limited at the
  unified-log level.

### Notes

- No behavior changes to the governor, the cycler, or the safety
  coordinator. All quick controls write through the same store APIs
  the right-click menu and Preferences already use.

---

- Fast user-switching awareness — observe
  `NSWorkspace.sessionDidResignActiveNotification` so throttled PIDs are
  released when the active session changes. Today the inflight
  dead-man's-switch catches this on the next cold launch, but a paused
  process can stay frozen until then.
- Power-source awareness at the governor preset layer, modulating caps
  tighter on battery and looser on AC. Complements the existing
  `BatteryAwareMode` threshold swap and the `onBatteryOnly` gate.

---

## [0.9.1] — 2026-04-26

Tier 0 safety hardening. No user-visible feature changes; all five fixes
target failure modes that could leave processes paused or silently lose
diagnostic signal. Audited internally and verified independently via
Codex CLI before landing.

### Fixed

- **Duty cycler runs off the main actor.** `ProcessThrottler.runCycle`
  was main-actor isolated; under UI pressure the SIGCONT half of a
  duty cycle could be delayed hundreds of ms while a process sat
  SIGSTOPped. Cycler is now a `nonisolated` synchronous function over
  `OSAllocatedUnfairLock`-guarded state, sleeping via `nanosleep(2)`
  so signal delivery is never gated on main-actor work.
- **Manual-throttle expiry tasks no longer stack.** Back-to-back
  `throttleFrontmost` / `throttleBundle` calls layered multiple
  auto-release sleepers per target, so the earliest one fired and
  released the manual duty mid-window. Pending tasks are now cancelled
  before scheduling a new one.
- **History writes log failures.** `HistoryLogger` previously
  swallowed every write error with `try?`; on a full disk the
  dashboard appeared frozen with no signal. Errors now log once per
  distinct cause via `os.Logger`, so diagnostic bundles capture the
  failure without flooding unified log.
- **Dead-man's-switch write is durable.** `SafetyCoordinator`'s
  inflight-record write now loops partial writes on `EINTR`, checks
  `fsync` and `rename` results, and fsyncs the parent directory so
  the rename itself survives power loss. Falls back to non-durable
  atomic write if the durable path fails.
- **Signal-send failures are logged.** Failed `signal()` calls other
  than `ESRCH` were silently swallowed; logs once per
  `(pid, signal, errno)` tuple so permission/state issues surface
  without log floods.

---

## [0.9.0] — 2026-04-20

Initial public release.

### Added

- **Thermal governor** — pauses user-owned processes via SIGSTOP/SIGCONT
  when the hottest sensor crosses a configurable threshold, with a
  foreground-app floor so your current work stays responsive. Off by
  default; opt-in per-rule.
- **Throttle rules** — pin per-process caps ("never let `Xcode` exceed 60%
  CPU when SoC > 80°C"), with a daily fire counter and human-readable
  "why this fired" surface.
- **Live thermal dashboard** — every HID thermal sensor the Air exposes,
  grouped by category (SoC / battery / ambient / PMIC), with sparkline
  history.
- **Menu bar readout** — one- or two-slot layout (hottest temp + CPU%)
  with a heartbeat pulse when throttling is active.
- **One-shot manual throttle** — right-click menu: "Throttle frontmost
  app at 30%."
- **Stay Awake** caffeinate-style modes: off, system-only (allow display
  sleep), system + display, and a timed "display on for N minutes, then
  system only" variant. Available from menu bar right-click and
  Preferences → General.
- **Global hotkey** — ⌘⌥P toggles pause/resume from anywhere, Carbon-based
  so no Accessibility permission is required.
- **Safety infrastructure** — rescue LaunchAgent, signal handlers on
  SIGTERM/SIGINT/SIGHUP/SIGQUIT, inflight dead-man's-switch file for
  crash recovery, 4 Hz stuck-cycle watchdog that force-SIGCONTs any PID
  stopped longer than 500ms, MetricKit diagnostic capture, and a RSS
  tripwire at 500MB.
- **First-run risk disclosure** — one-time modal on first launch
  explaining what the governor can do, that it's off by default, and
  AGPL-3.0 terms. Idempotent and versioned for future capability
  expansions.
- **Quit confirmation** — if rules are live at ⌘Q, Air Assist asks
  before releasing the paused PIDs. Suppressed by opt-quit (⌥⌘Q).
- **Update notifier** — once per day, checks GitHub's Releases API for
  a newer tag; surfaces a nudge in the menu-bar right-click when one
  exists. Click → opens the release page. No binary replacement, no
  installer, no telemetry. Opt-out in Preferences → Updates.
- **`airassist://` URL scheme** for Shortcuts.app, Raycast, Alfred, or
  `open airassist://pause` from the shell.
- **Dashboard + Preferences** windows remember size and position across
  launches.
- **Diagnostic bundle export** — Help → Export Diagnostics… produces a
  redacted zip suitable for bug reports.
- **Free-tier release pipeline** — tagged pushes build an ad-hoc signed
  `AirAssist-<version>.zip`, compute SHA256, and create a draft GitHub
  Release ready to attach to a Homebrew cask. No Apple Developer account
  required; uses `macos-15` runner with Xcode 16.
- **Homebrew cask scaffold** under `scripts/homebrew-tap-template/` with
  a formula targeting `:sequoia` + `:arm64`, and zap paths for clean
  uninstall.
- **Allowlist-based `scripts/publish.sh`** — mirrors the private
  development repo to a public one without exposing internal-only
  scripts, tests, or templates.
- **Single-instance guard** — bringing an existing AirAssist forward if
  the user double-launches.
- **Natural sort** for sensor names (`CPU Die 2` before `CPU Die 10`)
  via `localizedStandardCompare`.
- **OS thermal-state governor input** — when `respectOSThermalState`
  is on (default), `ProcessInfo.processInfo.thermalState` feeds into
  the aggression factor alongside temperature and CPU overshoot.
  Mapping: `nominal 0`, `fair 0.25`, `serious 0.6`, `critical 1.0`.
  Folded via `max(...)`, so nominal contributes nothing and the
  signal is strictly additive — a cool machine never throttles
  harder than the temp/CPU overshoot alone would dictate.
- **"Throttle only when on battery"** opt-in on the governor. When
  on AC with the flag enabled, caps stay armed-but-silent and the
  reason string surfaces why. Off by default.
- **Stay Awake: "Release when display sleeps"** preference. When on,
  drops the IOPM assertion on `screensDidSleepNotification` (lid
  close without external display, screen lock, idle display-off)
  and re-takes the same assertion on wake. Off by default — the
  existing `caffeinate(1)`-style behaviour remains the less-
  surprising default.
- **README "Automation" section** documenting the `airassist://`
  URL scheme with exact duration / duty formats and Shortcuts.app
  + shell examples.
- **README "Data sources" note** in Privacy, spelling out that
  Air Assist reads from `IOHIDEventSystemClient` (public HID API,
  same interface `powermetrics` uses), does not call any private
  SPI, does not touch SMC, and ships no bundled binary blob.

### Changed

- **License: MIT → AGPL-3.0-or-later.** AGPL permits all use,
  including commercial, provided derivatives stay AGPL and source is
  shared with users — including users of a modified version reached
  over a network. A separate commercial license is available from the
  maintainer for parties who want to redistribute or embed Air Assist
  without AGPL's copyleft obligations.
- **macOS 15 (Sequoia) minimum.** Deployment target is 15.0; uses
  Observation, strict concurrency (Swift 6), and modern SwiftUI.
- **Distribution: ad-hoc signed, not notarized.** Deliberate choice —
  Homebrew cask install skips the Gatekeeper/quarantine path cleanly,
  and the AGPL position requires parity for forks. See
  [docs/releasing.md](docs/releasing.md) for the full rationale.
- **Bundle identifier:** `com.airAssist.app` → `com.sjschillinger.airassist`
  (clean reverse-DNS, pre-launch).
- **SoC sensor group first** in the category order, so the most
  actionable readings stay above long `CPU Die` lists on M-series Pros.
- **"Sensors unavailable" state** shown explicitly when
  IOHIDEventSystemClient returns no readings after ≥ 5 s.
- **First launch hides obvious sensor noise** (`CPU Die 5..N`, `Other`
  category) so the popover is readable on M-series Pro/Max parts.
  All sensors remain re-enableable in Preferences → Sensors.
- **Governor default stays `off`** — throttling requires explicit opt-in.
- **README:** prominent "USE AT YOUR OWN RISK" warning, Apple trademark
  disclaimer, license-terms table, install section that leads with
  Homebrew and covers the one-time `xattr -dr com.apple.quarantine`
  step for manual downloads, and a SHA256 verification one-liner.
- **Privacy section:** documents the one daily GitHub API call and
  how to disable it.
- **Schema-safe persistence** — `GovernorConfig` has a custom
  `init(from:)` with `decodeIfPresent` for every field so older configs
  survive schema additions without being silently wiped.

### Removed

- **Sparkle.** Sparkle's auto-installer requires a Developer ID
  signature to replace the running binary cleanly — incompatible with
  our ad-hoc signing stance. Replaced by the GitHub Releases API
  notifier described above.

### Security

- **No root, ever.** The app operates entirely at user privilege and
  refuses to target processes the user doesn't own.
- **No kernel extension, no helper daemon, no `SMAppService`-installed
  privileged component.**
- **Graceful quit handlers** SIGCONT every paused PID before the
  process exits. Hard-crash recovery replays the inflight file on
  next launch.

---

[Unreleased]: https://github.com/sjschillinger/airassist/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/sjschillinger/airassist/releases/tag/v0.9.0
