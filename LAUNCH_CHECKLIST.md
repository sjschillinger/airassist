# AirAssist — Launch Readiness Checklist

Dev-only document. NOT published to the public repo (see `scripts/publish.sh`
allowlist). Checked into the private dev repo so nothing slips.

Last updated: 2026-04-18

---

## Legend

- [ ] pending
- [~] in progress
- [x] done
- **Priority:** 🚨 blocks launch · 🧹 ship-blocking polish · 🛡️ correctness · 📦 hygiene · 💡 non-obvious

---

## Launch philosophy (revised 2026-04-18)

**Ship v1.0 feature-complete, not an 0.1.0 with a roadmap.**

Previous framing was "launch 0.1.0, iterate to 1.0 publicly." New
framing: **launch only when the app feels done**, with no "coming soon"
language anywhere. After launch, the only updates expected are:

- Bug fix patches (0.1.1 etc — inevitable, accept them)
- macOS version / device compatibility updates
- Community PRs accepted on the owner's own timeline (translations,
  minor polish)

Not expected: feature additions. The v1.0 surface is the v1.0 surface.

This pushes launch later but protects the first-impression story — and
for an OSS utility where first-impression *is* the discovery moment
(HN, r/macapps), that's the right trade. See "v1.0 feature
completeness" below for what this promotes into scope, and "Declined
scope" for what we're explicitly saying no to.

---

## 🚨 Blocks launch (must fix before public release)

- [x] **#1 Signing & distribution infrastructure** — free-tier path is
  the permanent plan, not a temporary stopgap
  - ✅ Free-tier release pipeline: ad-hoc signed zip via Homebrew cask
    (`.github/workflows/release.yml` + `scripts/homebrew-tap-template/` +
    `docs/releasing.md`). Draft-only; nothing publishes without a manual
    click.
  - **Decision (2026-04-18): do NOT notarize.** Reasoning:
    - Homebrew cask install strips quarantine, so Gatekeeper is
      already solved for `brew`-installed users. Notarization adds no
      real security or UX benefit for that path.
    - AGPL-3.0 means forks are expected and welcome. If we set
      notarization as the "official" signal, we accidentally raise
      the barrier for any contributor who wants to ship their own
      build. Source-first trust model is more consistent with OSS.
    - Notarized binaries complicate reproducible builds (Apple's
      signature timestamp differs per submission).
    - $99/yr is better spent on literally anything else for a free
      utility.
    - The source + Homebrew tap is the trust root; Apple's vouching
      is redundant.
  - Revisit **only** if we start distributing outside Homebrew (direct
    `.dmg` download from a website), if casual-user install friction
    becomes the #1 support issue, or if we ever pursue the Mac App
    Store (which would also require sandboxing — declined in #32).
  - [ ] Still-pending: create the separate `homebrew-airassist` public
    repo from `scripts/homebrew-tap-template/` before tagging 0.1.0.

- [x] **#2 Sparkle framework not actually linked**
  - Resolution: checklist was wrong — no `SUFeedURL` / `SUPublicEDKey`
    keys existed in Info.plist or project.yml. Nothing to strip.
    README + CHANGELOG updated to stop promising Sparkle for 0.1.x.
    Sparkle is a future feature; updates happen via `brew upgrade`.

- [x] **#3 Final bundle identifier** — `com.sjschillinger.airassist`.
  Applied in project.yml, Info.plist, Constants.swift, UserDefaults
  key, Homebrew cask zap paths.

- [x] **#4 Hard-coded `airassist.app` domain** — never actually written
  into Info.plist (see #2). Moot.

- [x] **#5 Privacy statement vs. auto-update** — resolved by #2.
  README now states 0.1.x makes **zero** outgoing network requests.

---

## 🧹 Ship-blocking polish

- [x] **#6 Natural sort for sensor names** — 618ca3f
- [x] **#7 Category order in popover** — reordered enum (SoC first)
- [x] **#8 Condense 14× "CPU Die N" rows** — category headers in the
  detailed popover are now collapsible. Auto-collapses categories
  with >5 sensors on first sight; shows hottest value + count when
  collapsed. User collapse/expand choices persist across launches.
  Resolved this session.
- [~] **#9 App icon quality check** — bespoke, not placeholder, but
  dated. Thermometer + air-flow metaphor on a blue→red gradient. Uses
  glossy top highlight (Big Sur+ moved to matte). Ship-acceptable for
  0.1.0; consider a modernization pass (matte finish, subtle depth,
  drop the glossy highlight) or a paid designer before 1.0.
- [ ] **#10 Menu bar icon legibility (light + dark menu bar)**
  - Screenshot on light wallpaper + dark wallpaper
  - Pulse minAlpha 0.35 may wash out on light bars
- [x] **#11 First-launch experience** — `FirstLaunchSeeder` runs once
  after initial sensor discovery. Hides `CPU Die 5..N` + the `Other`
  category (PMIC/rails) by default; keeps SoC, GPU, Battery, Storage,
  CPU Die 1..4 visible. Governor stays **off** by default — throttling
  user processes without explicit opt-in would be a surprising
  default for an OSS utility.
- [x] **#12 Product name casing audit** — fixed HistoryView user-visible string
- [x] **#13 Empty states** — popover + dashboard sensor grid + "all disabled"
- [ ] **#14 Accessibility Inspector pass**
  - Run Xcode Accessibility Inspector on dashboard + popover + prefs
  - Every control must have a label; verify VoiceOver flow end-to-end
- [x] **#15 Preferences + Dashboard window remember size/position** — fixed `center()` override

---

## 🛡️ Safety & correctness

- [ ] **#16 Verify SIGSTOP actually lands on a real process**
  - Runnable: `./scripts/manual-tests/verify-sigstop-lands.sh`
  - See `docs/engineering-references.md` §1 for SIGSTOP semantics
    and §4 for `ps` STAT codes.
- [ ] **#17 SafetyCoordinator crash-recovery live test**
  - Start throttling → `kill -9` AirAssist → verify target resumes
  - Single most important behavior; if broken, launch is bad.
  - TODO: convert to `scripts/manual-tests/verify-crash-recovery.sh`
- [ ] **#18 Sleep/wake cycle handling**
  - Observe `NSWorkspace.willSleepNotification`/`didWakeNotification`
  - Decide: resume all throttled PIDs on sleep? Re-arm on wake?
  - See `docs/engineering-references.md` §3 for notification semantics,
    Power Nap gotcha, and the "posted on NSWorkspace.shared.notificationCenter"
    trap.
- [ ] **#19 PID reuse / process-exit mid-throttle**
  - Detect stale PIDs via kqueue `EVFILT_PROC NOTE_EXIT` (preferred
    over polling — see `engineering-references.md` §2).
  - Don't send SIGSTOP to recycled PIDs.
- [x] **#20 Thermal sensor read failure path** — `ReadState` enum + UI in popover & dashboard

---

## 📦 Release hygiene

- [x] **#21 Project file source of truth** — `project.yml` wins.
  `.xcodeproj` stays checked in so `git clone && open AirAssist.xcodeproj`
  works without XcodeGen, but CONTRIBUTING now explicitly documents
  that the pbxproj is generated output and must be kept in sync via
  `xcodegen generate`.
- [ ] **#22 Real test coverage for core safety paths**
  - Current: 17 tests (mostly formatting/config)
  - Add: ThermalGovernor duty math, ThrottleRuleEngine rule firing,
    ProcessThrottler cycle math, SafetyCoordinator recovery
- [x] **#23 CHANGELOG.md + v0.1.0 release notes** — Keep-a-Changelog format
- [x] **#24 GitHub issue + PR templates** — bug, feature, config, PR
- [x] **#25 SECURITY.md** — private disclosure flow + scope
- [x] **#26 CODE_OF_CONDUCT.md** — links to Contributor Covenant 2.1
- [x] **#27 CONTRIBUTING.md** — build/test/style/scope
- [x] **#28 Strip `DEVELOPMENT_TEAM`** — verified not present in `project.yml`

---

## 💡 Non-obvious concerns

- [x] **#29 Name / trademark check — DECISION: keep AirAssist**
  - Collisions exist but in unrelated categories (AI classroom product,
    Relativity legal-tech feature, laser-cutter hardware). Trademark
    risk for an OSS Mac utility in a different product class is low.
    SEO dilution accepted.
  - Decided 2026-04-18. Everything downstream settles on this name:
    repo URL `sjschillinger/airassist`, bundle ID
    `com.sjschillinger.airassist`, Homebrew cask `airassist`, README
    copy.
- [x] **#30 Fanless-only positioning — have the HN answer ready** —
  README now has a "Why MacBook Air only?" section with the runs-on-Pros
  caveat + NON_AIR_ROADMAP pointer.
- [x] **#31 Competitor comparison blurb** — README "How this compares
  to other tools" section with category-by-category rows (fan-control
  utilities / turbo-bin togglers / commercial CPU cappers / CLI pause
  loops), plus a one-paragraph HN/Reddit answer. Named products kept
  out per the pre-commit hook.
- [x] **#32 Sandboxing decision — documented in README** — new Privacy + Sandboxing sections
- [ ] **#33 Notarization dry-run with entitlement**
  - Submit test build with `com.apple.security.temporary-exception.iokit-user-client-class`
  - Don't discover on launch day that Apple rejects it

---

## Suggested sequence

1. **This week:** #16 #17 #19 (correctness) + #9 (icon) + #29 (name check)
2. **Next week:** #1 #2 #3 #4 (signing + Sparkle infrastructure)
3. **Soft launch prep:** #11 #13 #14 (UX) + #23–#27 (hygiene)
4. **Public launch:** tag, publish via `scripts/publish.sh`, write HN post,
   answer #30 #31 in README

---

## Active gameplan (superseded 2026-04-18 — see "Critical path to v1.0 tag" below)

Kept for historical context. The "Must-fix / Should-fix / Nice-to-have"
framing below reflects the old 0.1.0-then-iterate plan; replaced by
the v1.0-complete framing. Treat any conflicts between this block and
"Critical path to v1.0 tag" in favor of the latter.

### Must-fix before tagging 0.1.0
1. **#16 / #17 Live safety tests** — `yes > /dev/null &` + `ps -o pid,stat,comm`
   to confirm `T` state, then `kill -9` AirAssist mid-throttle and confirm
   the target resumes. Non-negotiable.
2. **#3 Bundle identifier** — pick final reverse-DNS, not `com.airAssist.app`.
3. **#2 Sparkle decision** — link it properly OR strip the placeholder
   `SUFeedURL` / `SUPublicEDKey` from Info.plist. Can't ship with
   declared-but-absent Sparkle.
4. **#4 Appcast URL** — if Sparkle stays: GitHub Pages appcast, or drop
   auto-update for 0.1.0.
5. **#29 Name / trademark** — 10-min USPTO TESS search; have fallback
   name ready.

### Should-fix (ship quality)
6. **#9 App icon** — confirm it's not a placeholder.
7. **#10 Menu bar icon** — screenshot on light + dark wallpaper.
8. **#11 First-launch** — sensible defaults so first 5s are useful
   (pre-select best 2 sensors, default governor to "armed").
9. **#14 Accessibility Inspector pass** — dashboard, popover, prefs.
10. **#21 Project file source-of-truth** — pick `project.yml` OR
    `.xcodeproj`, delete the other.
11. **Publish allowlist fix** — extend `scripts/publish.sh` allowlist to
    include `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
    `CHANGELOG.md`, `.github/ISSUE_TEMPLATE/`,
    `.github/pull_request_template.md`.

### Correctness + UX items promoted to must-fix (2026-04-18)

Previously "nice-to-have / can slip." Under the v1.0-complete framing,
all four ship before tag:

- **#8 Condense CPU Die rows** — default UX has 14 near-identical rows
  right now; unacceptable in a "finished" build
- **#18 Sleep/wake handling** — this is correctness, not polish. Bad
  behavior across sleep/wake is the kind of bug that produces loud
  tweets. Ship with `NSWorkspace.willSleepNotification` /
  `didWakeNotification` observers, decided resume-on-sleep policy.
- **#19 PID reuse / process-exit mid-throttle** — safety-adjacent.
  kqueue `EVFILT_PROC NOTE_EXIT` on every throttled PID. Never send
  SIGSTOP to a recycled PID.
- **#22 Real test coverage for core safety paths** — ThermalGovernor
  duty math, ThrottleRuleEngine rule firing, ProcessThrottler cycle
  math, SafetyCoordinator recovery. Required before public launch given
  reputation stakes.

### Launch day
- Create public `homebrew-airassist` repo from
  `scripts/homebrew-tap-template/`.
- Replace `TODO_USER` placeholders everywhere (README, cask formula,
  release.yml release-body, publish.sh if needed).
- Tag `v0.1.0`, wait for draft release, verify the zip installs + runs,
  click Publish, bump cask `sha256`.
- Post answers to #30 (fanless-only positioning) + #31 (competitor
  blurb) — either in README or reserved in a scratch file for HN/Reddit.

### Recommended next session
Start with #16 / #17 — the things that would be most embarrassing to
ship broken. Then the 4 remaining 🚨 blockers (#2, #3, #4, #29).

---

## 🆕 Added from 2026-04-18 pre-launch review

Items surfaced while reviewing everything end-to-end. Some overlap with
earlier entries — cross-references in parens.

### Functional smoke tests (need explicit runs, not just code review)
- [ ] **#34 Rule re-attach across app relaunch** — add per-app rule, kill
  target app, relaunch it, confirm new PID gets throttled
- [ ] **#35 Pause auto-resume** — pause 15 min, wait for expiry, confirm
  both governor + rules resume (extends #17)
- [ ] **#36 Stay Awake assertion verification** — each of the 4 modes,
  check `pmset -g assertions` shows the right `PreventUserIdleSystemSleep`
  / `PreventUserIdleDisplaySleep` entries
- [ ] **#37 Lid-close with `displayThenSystem` mode** — display sleeps
  after timeout, system stays awake
- [ ] **#38 Force-quit mid-throttle cleanup** — next launch has no stuck
  SIGSTOP'd processes (extends #17)

### UX polish (new since #11 landed)
- [ ] **#39 Onboarding sheet on first launch** — #11's `FirstLaunchSeeder`
  handles sensor defaults but there's no explanatory panel. Users see a
  menu bar icon and no context. Add a one-time sheet: what this does, why
  SIGSTOP is safe, link to GitHub. High-impact for installer retention.
- [ ] **#40 Tooltips on non-obvious controls** — Stay Awake mode variants,
  duty %, pause durations, summary-mode toggle
- [ ] **#41 Keyboard navigation in prefs** — tab order, Esc closes,
  checked alongside #14
- [ ] **#42 Popover width at low sensor counts** — single-sensor summary
  mode still reserves ~260pt; tighten

### Feature gaps worth closing pre-1.0
- [ ] **#43 "Why is this throttled?" affordance** — hovering a live-
  throttled row in the popover shows source (governor / rule / manual)
- [ ] **#44 Right-click throttle adjust from popover** — change duty or
  release directly without opening prefs
- [ ] **#45 Temperature history sparkline in popover** — `HistoryLogger`
  already captures; just wire a 10-min sparkline row
- [ ] **#46 Export diagnostic bundle** — one-click save of logs + config
  + recent sensor history, for bug reports. Saves enormous back-and-
  forth on GitHub issues.
- [ ] **#47 Quit confirmation if rules are currently active** — prevents
  the "why did Chrome suddenly get fast" surprise

### Stability (covers #22 but broader)
- [ ] **#48 Thread Sanitizer 30-min run** — catch MainActor violations
- [ ] **#49 Instruments / Leaks 1-hour run** — memory + handle growth
- [ ] **#50 Perf at 1000+ PIDs** — `ProcessInspector` must stay under a
  few ms per cycle; simulate with spawned noop children

### Launch-day logistics
- [ ] **#51 Pick ONE launch channel** — HN Show / r/macapps / lobste.rs.
  One thoughtful post beats five.
- [x] **#52 Issue responsiveness expectation** — README "Support &
  response times" section sets the one-maintainer-spare-time expectation
  and points to the diagnostic bundle for bug reports.

---

## 🎯 v1.0 feature completeness (added 2026-04-18)

The "feels finished" features that turn a capable utility into one
users won't feel compelled to request additions to. Each item is
scoped to be shippable without opening the door to follow-up scope.

### Platform-native integrations
- [x] **#53 URL scheme handler** — shipped this session.
  - `airassist://pause[?duration=15m|1h|30s|forever]`
  - `airassist://resume`
  - `airassist://throttle?bundle=<id>&duty=<0.5|50%>[&duration=1h]`
  - `airassist://release?bundle=<id>`
  - Registered via `CFBundleURLTypes`; handled in
    `AppDelegate.application(_:open:)`. Pure parser covered by 12
    unit tests in `URLSchemeHandlerTests.swift`. Ready to be the
    dispatch layer for #54 AppIntents.
- [ ] **#54 Shortcuts.app actions (AppIntents)** — three actions to
  start: "Pause AirAssist", "Resume AirAssist", "Throttle Frontmost
  App". Builds on #53; AppIntents framework makes this ~100 LOC on
  modern macOS.
- [ ] **#55 Focus Filter integration** — app appears in Settings →
  Focus → app-specific filters. User picks pause/preset per Focus
  mode (Work → Aggressive, Personal → Off, etc.). Uses
  `INFocusFilter` API. Native-feeling integration users expect in a
  v1.0 Mac app.

### First-run / discoverability wins
- [ ] **#56 Global pause hotkey** — ⌘⌥P default, user-configurable in
  prefs. Toggle pause/resume from anywhere. ~50 LOC with
  `NSEvent.addGlobalMonitorForEvents` or Carbon hotkey API. Massive
  perceived-value multiplier.
- [ ] **#57 Rule templates / starter library** — solves the blank-
  canvas problem. Ship a curated list users can enable individually:
  Chrome helpers, Slack, Docker Desktop, Teams, Zoom, Electron apps
  (generic), Spotlight indexing. "Enable all" + per-row toggles.
- [ ] **#58 Threshold presets** — Conservative / Balanced / Aggressive
  one-click profiles in General prefs. Exposes the same underlying
  numbers that power users can still edit in Thresholds prefs.
  Removes "what numbers should I pick?" paralysis for non-experts.

### Smart-default behaviors
- [ ] **#59 Battery-aware auto-mode** — when on battery, apply a
  stricter threshold preset automatically. When plugged, revert.
  Reads `IOPSGetProvidingPowerSourceType`. Matches the fanless-Air
  use case perfectly; opt-in via Preferences checkbox.
- [ ] **#60 Scheduled / time-windowed rules** — each rule gains an
  optional schedule ("active 9am–6pm weekdays"). Currently rules are
  all-or-nothing. Unlocks "throttle Slack during work hours only"
  type use cases. Data model extension in `ThrottleRule`, small UI
  addition in rules editor.

---

## 🚫 Declined scope (explicitly out of v1.0 and v1.x)

Documenting what we're saying no to, so it doesn't creep back in.

- **Fan curve profiles / MacBook Pro fan control** — different product.
  AirAssist is fanless-first. Non-Air support stays at "it runs, you
  read sensors, governor/rules work" — no active fan management.
  Forks/sibling projects welcome.
- **Per-app CPU budget (vs duty %)** — different abstraction
  requiring dynamic duty adjustment. Duty % is honest and maps 1:1 to
  SIGSTOP. v2 material if ever.
- **Localization beyond English** — you can't validate translations
  you can't read. English-only at launch; CONTRIBUTING invites
  community translation PRs, accepted post-launch per language.
- **Telemetry (even opt-in)** — the project's value prop includes
  "zero network requests." Shipping telemetry changes the character
  of the project. Permanent no.
- **Mac App Store** — requires sandboxing, incompatible with our
  IOKit entitlement. Permanent no (see #32).
- **In-app Sparkle updater** — `brew upgrade --cask airassist` is
  sufficient and consistent with "no network requests." Not shipping
  Sparkle in v1.x (see #2).
- **Notarization** — declined as an OSS trust-model choice (see #1).

---

## Critical path to v1.0 tag

Under the v1.0-complete framing, the "if time is tight" framing is
replaced with an explicit critical path. Roughly ordered — do each
group before moving to the next.

### 1. Correctness gates (ship-breakers)
- #16 / #17 — live safety tests: `T`-state verification + crash-
  recovery release
- #18 sleep/wake cycle handling
- #19 PID reuse / process-exit (kqueue NOTE_EXIT)
- #22 test coverage for governor + rule engine + throttler + safety

### 2. Naming + identity (rename-blocks-everything)
- #29 name / trademark resolution — if we rename, it touches repo
  URL, bundle ID last segment, Homebrew cask name, README, icon, app
  display name. Do this FIRST so everything else settles on the
  final name.

### 3. UX gaps that kill first impressions
- #39 onboarding sheet
- #57 rule templates / starter library (fixes the blank-canvas
  problem #39 otherwise exposes)
- #58 threshold presets
- #8 condense CPU Die rows
- #10 menu bar legibility on light + dark wallpapers
- #14 Accessibility Inspector pass

### 4. Feature completeness (the v1.0 thesis)
- #53 URL scheme
- #54 Shortcuts.app actions
- #55 Focus Filter integration
- #56 global pause hotkey
- #59 battery-aware auto-mode
- #60 scheduled rules
- #45 sparkline in popover
- #46 export diagnostic bundle
- #43 "why is this throttled?" affordance
- #44 right-click throttle from popover
- #47 quit confirmation with active rules

### 5. Stability profiling
- #48 Thread Sanitizer 30-min run
- #49 Instruments / Leaks 1-hour run
- #50 perf at 1000+ PIDs

### 6. Launch-day logistics
- TODO_USER placeholder sweep everywhere
- Create public `homebrew-airassist` repo
- #10 README screenshots (light + dark)
- #30 fanless-only positioning answer
- #31 competitor comparison blurb
- #51 launch-channel decision
- #52 response-time expectation in README

**Note on notarization:** not on this list and never will be — see #1.
The Homebrew cask pipeline solves Gatekeeper without notarization and
this is the permanent model, not a stopgap.

---

## Realistic timeline

With the expanded v1.0 scope this is no longer a "weekend to tag"
project. Honest estimate:

- Groups 1+2 (correctness + rename): 1 weekend of focused work
- Group 3 (UX gaps): 1 weekend
- Group 4 (new features): 2–3 weekends — the bulk of the work
- Group 5 (profiling): 1 evening
- Group 6 (launch day): 1 evening + verification time

Call it **4–5 weekends of real time** from here, give or take. Faster
if AppIntents / Focus Filter / URL scheme turn out simpler than
estimated; slower if the stability profiling surfaces a real leak or
perf issue that needs architectural work.

---

## Completed

- ✅ Phase 1 scaffolding (commit `cbb0d7c`): `.gitignore`, References/
  untracked, pre-commit hook, publish.sh, CI workflows, LICENSE, README.
- ✅ Natural sensor sort (commit `618ca3f`).
- ✅ Stay Awake + launch checklist (commit `4338654`).
- ✅ Quick-win batch (12 items: #7, #12, #13, #15, #20, #23–#28, #32).
- ✅ Free-tier distribution pipeline (ad-hoc signed Homebrew cask):
  rewrote `release.yml`, added `scripts/homebrew-tap-template/`,
  wrote `docs/releasing.md`, updated README install section.
- ✅ Blocker batch (8 items): #2, #3, #4, #5, #11, #21, #29 search, #9
  inspection, publish allowlist extension.
