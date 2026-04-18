# Contributing to Air Assist

Thanks for thinking about it. Air Assist is a small project, so the
contribution bar is mostly "does this work on a real Air, and does it
keep the existing behaviour intact?"

This doc covers everything from first-time build to PR etiquette.

---

## Before you start

- Read the [Code of Conduct](CODE_OF_CONDUCT.md).
- For a **bug**, check [existing issues](../../issues?q=is%3Aissue) first.
- For a **new feature**, please open an issue to discuss before writing
  code — especially anything that changes throttling behaviour, adds a
  preference, or touches the menu bar. Small polish PRs can go straight
  to a PR without an issue first.
- Security issues go through [SECURITY.md](SECURITY.md), **not** the
  public issue tracker.

---

## Build & run

Air Assist uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to
generate the `.xcodeproj` from `project.yml`, so the pbxproj stays
diff-friendly.

**`project.yml` is the source of truth.** The generated
`AirAssist.xcodeproj` is checked in so new contributors can
`git clone && open AirAssist.xcodeproj` without installing XcodeGen,
but never hand-edit the pbxproj. Workflow when you change build
settings, add a file, or bump the bundle ID:

```bash
# edit project.yml
xcodegen generate
git add project.yml AirAssist.xcodeproj
git commit
```

PRs that drift the pbxproj away from what `xcodegen generate`
produces will be asked to regenerate and recommit.

```bash
git clone https://github.com/TODO_USER/airassist.git
cd airassist

brew install xcodegen
xcodegen generate

open AirAssist.xcodeproj
```

Minimum requirements:

- macOS 15 (Sonoma) or later
- Xcode 16 or later
- Apple Silicon Mac (M-series)

---

## Running the tests

```bash
xcodebuild -project AirAssist.xcodeproj \
           -scheme AirAssist \
           -destination 'platform=macOS' \
           -configuration Debug \
           CODE_SIGNING_ALLOWED=NO \
           test
```

CI runs this on every push and pull request. PRs that break tests will
not be merged; please run the suite locally first.

---

## Install the pre-commit hook

```bash
./scripts/install-hooks.sh
```

This symlinks `scripts/hooks/pre-commit` into `.git/hooks/`. The hook
blocks commits that mention third-party commercial products by name.
The same scan runs in CI; installing the hook locally just saves you a
round-trip.

---

## Coding guidelines

### Architecture

- **Models:** plain `@Observable` types under `AirAssist/Models/`.
  No side effects, no network, no IO.
- **Services:** background work lives here. Services are `@MainActor`
  unless there's a concrete reason to be off-main; prefer `Task`s over
  GCD. Side effects are confined to services.
- **Store:** `ThermalStore` is the single source of truth the UI reads
  from. Views never reach into services directly.
- **Views:** SwiftUI for everything except menu-bar and popover glue,
  which stays AppKit (see `MEMORY.md` note about `NSHostingView` in
  status items).

### Safety-critical code

Any change to these files needs a corresponding test **and** a
live-process verification:

- `AirAssist/Services/ProcessThrottler.swift`
- `AirAssist/Services/ThermalGovernor.swift`
- `AirAssist/Services/ThrottleRuleEngine.swift`
- `AirAssist/Services/SafetyCoordinator.swift`

"Live verification" means: start a busy process (`yes > /dev/null &`),
exercise the change, confirm with `ps -o pid,stat,comm` that the
target enters and leaves `T` (stopped) state as expected. If
`SafetyCoordinator` changes, also `kill -9` Air Assist mid-throttle
and confirm the target resumes.

### Style

- Swift 6, strict concurrency.
- 4-space indent (enforced by `project.yml`).
- Comments explain *why*, not *what*. Trivial comments get deleted in
  review.
- User-facing strings say "Air Assist" (two words). "AirAssist" is
  reserved for bundle identifiers, file paths, and code symbols.
- Prefer `localizedStandardCompare` over `<` when sorting strings
  users will see — digits should order numerically.

### Commits

- One logical change per commit.
- Subject line: imperative mood, under ~70 chars.
- Body: wrap at ~72 chars, explain the *why* where it isn't obvious.
- We do not use Conventional Commits; plain English beats `feat:`.

---

## Originality of code and assets

All source code in this repository is original work, written against
publicly-documented Apple APIs (IOHIDEvent, libproc, POSIX signals) and
standard Unix idioms. No code, strings, constants, sensor mappings, or
assets have been copied or derived from any third-party commercial
application.

Art assets (app icon, menu bar glyphs) are original work for this
project. If you contribute new assets, they must be your own original
work or under a license compatible with AGPL-3.0; include attribution
in this file.

PRs whose diffs resemble decompiled Swift/Objective-C from another
app — or that introduce hard-coded tables of sensor keys, process
names, or magic constants without a cited public source — will be
rejected on sight.

## Scope

Air Assist is **fanless-Air-first**. Non-Air features (fan control,
per-fan curves, System Settings integrations) live on a separate
roadmap and generally will not be merged unless discussed in an issue
first. This keeps the default experience coherent.

We are also **OSS-first, not App Store-first**. Contributions that
would require sandboxing or an XPC helper are fine in principle but
need an RFC-style issue before code lands.

---

## Pull requests

1. Fork the repo.
2. Branch from `main`.
3. Make your change, run the tests, run the app on a real Mac.
4. Open a PR against `main`. Fill in the PR template.
5. Expect review comments. We're trying to keep the codebase small
   and legible — don't take "can we do less?" personally.

Thanks again.
