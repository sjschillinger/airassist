# Changelog

All notable changes to Air Assist are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

Dates are in ISO 8601 (YYYY-MM-DD).

## [Unreleased]

### Added
- Natural sort for sensor names, so `CPU Die 2` sorts before `CPU Die 10`.
- **Stay Awake** caffeinate-style modes: off, system-only (allow display sleep),
  system + display, and a timed "display on for N minutes, then system only"
  variant. Available from the menu bar right-click and Preferences → General.
- SensorCategory reordered so the SoC group is first, keeping the most
  actionable readings above long CPU Die lists on M-series Pros.
- Dashboard and popover show an explicit "Sensors unavailable" state when
  IOHIDEventSystemClient returns no readings after ≥5s.
- All sensor name sorts use `localizedStandardCompare` for human-friendly
  numeric ordering.
- Preferences and Dashboard windows now remember their size and position
  across launches.
- GitHub Actions: CI build + test workflow, forbidden-strings guard,
  tag-driven release skeleton.
- Free-tier release pipeline: tagged pushes build an ad-hoc signed
  `AirAssist-<version>.zip`, compute SHA256, and create a **draft**
  GitHub Release ready to attach to a Homebrew cask.
- Homebrew tap scaffold under `scripts/homebrew-tap-template/` (dev-only)
  with a cask formula + README for the separate `homebrew-airassist` repo.
- `docs/releasing.md` — end-to-end release flow (tag → draft →
  publish → tap bump).
- Allowlist-based `scripts/publish.sh` export to a separate public repo, plus
  a pre-commit hook blocking stray references to third-party products.

### Changed
- README clarifies the sandboxing decision and the single outgoing
  network request (Sparkle appcast).
- Install instructions lead with `brew install --cask` and cover the
  one-time `xattr -dr com.apple.quarantine` step for manual downloads.
- Bundle identifier: `com.airAssist.app` → `com.sjschillinger.airassist`
  (clean reverse-DNS, pre-launch). UserDefaults key for threshold
  settings renamed accordingly; pre-1.0 users will see defaults on
  first launch after upgrading.
- README/CHANGELOG no longer promise a Sparkle in-app updater for
  0.1.x — updates come via `brew upgrade`. In-app Sparkle stays on
  the roadmap.
- First launch hides obvious sensor noise by default (`CPU Die 5..N`
  and the `Other` category) so the popover is readable on M-series
  Pro/Max parts. All sensors remain re-enableable in
  Preferences → Sensors. Governor default stays `off` — throttling
  requires explicit opt-in.
- Publish allowlist extended to include community health files
  (CONTRIBUTING, SECURITY, CoC, CHANGELOG, issue/PR templates, docs/).
- CONTRIBUTING clarifies that `project.yml` is the source of truth and
  the generated `.xcodeproj` must be kept in sync via
  `xcodegen generate`.

### Fixed
- Popover no longer renders a blank rectangle when all sensors are
  disabled or have not yet loaded.

---

## [0.1.0] — TBD (first public release)

Initial public release. See the `Unreleased` section above until this
tag ships; content will be rolled forward on release day.

[Unreleased]: https://github.com/TODO_USER/airassist/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/TODO_USER/airassist/releases/tag/v0.1.0
