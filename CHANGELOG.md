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
- Allowlist-based `scripts/publish.sh` export to a separate public repo, plus
  a pre-commit hook blocking stray references to third-party products.

### Changed
- README clarifies the sandboxing decision and the single outgoing
  network request (Sparkle appcast).

### Fixed
- Popover no longer renders a blank rectangle when all sensors are
  disabled or have not yet loaded.

---

## [0.1.0] — TBD (first public release)

Initial public release. See the `Unreleased` section above until this
tag ships; content will be rolled forward on release day.

[Unreleased]: https://github.com/TODO_USER/airassist/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/TODO_USER/airassist/releases/tag/v0.1.0
