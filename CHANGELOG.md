# Changelog

All notable changes to Air Assist are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

Dates are in ISO 8601 (YYYY-MM-DD).

## [Unreleased]

_No changes yet. See [0.9.0](#090--2026-04-19) for the initial release._

---

## [0.9.0] — 2026-04-19

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

### Changed

- **License: MIT → AGPL-3.0.** Non-commercial use remains free; any
  fork or derivative must stay AGPL and share source. A separate
  commercial license is available from the maintainer.
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
