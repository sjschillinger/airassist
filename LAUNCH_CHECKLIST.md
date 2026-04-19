# AirAssist — Launch Readiness Checklist

Dev-only document. NOT published to the public repo (see `scripts/publish.sh`
allowlist). Checked into the private dev repo so nothing slips.

Last updated: 2026-04-19 (post-integration-suite sync)

---

## Remaining work (synced 2026-04-19)

All code-side v1.0 items done. Runtime-safety suite is now automated —
`scripts/run-integration.sh` runs 10 tests in ~85s covering #16 #17
#19 #34 #35 #36 #37 #38. What remains:

**Runtime verification (automated, green):**
 - [x] #16 SIGSTOP lands — `test_16_SIGSTOPLands`
 - [x] #17 Crash-recovery — `test_17_CrashRecoveryResumesOrphaned`
 - [x] #18 Sleep/wake — physically verified 2026-04-19 (SleepWakeObserver
       logs confirmed willSleep release + didWake resume)
 - [x] #19 PID-reuse — `test_19_ExitWatcherReleasesPromptly`
 - [x] #34 Rule re-attach — `test_34_RuleReattachAfterRelaunch`
 - [x] #35 Pause auto-resume — `test_35_PauseAutoResumes` +
       `test_35_ExplicitResumeClearsPause`
 - [x] #36 Stay Awake — `test_36_StayAwakeSystemAssertionRegistersWithPMSet`
       + `test_36_StayAwakeDisplayAssertion`
 - [x] #37 displayThenSystem downgrade — `test_37_DisplayThenSystemDowngrades`
       (auto) + `verify-lid-close-displaythensystem.sh` (hinge, passed
       2026-04-19; runbook expectation corrected — see Remaining-work
       entry for the clamshell/assertion finding)
 - [x] #38 Force-quit clean — `test_38_SIGTERMResumesInflight`

**Still needs physical hardware:**
 - [x] #37 lid-close portion — physically verified 2026-04-19. Empirical
       finding corrected the runbook's expectation: on Apple Silicon
       portables without an external display, clamshell close ALWAYS
       sleeps the system regardless of `PreventUserIdle{System,Display}Sleep`
       (that assertion family only blocks idle-initiated sleep — closed-
       lid requires an external display). pmset log confirmed
       `Entering Sleep state due to 'Clamshell Sleep'` fires in both
       pre- and post-downgrade phases. Runbook rewritten to verify
       what's actually meaningful: clean assertion lifecycle across
       the sleep-wake cycle (no stuck or double-released assertions).
       In-app caveat added to `stayAwakeExplanation` so users aren't
       misled into expecting "Stay Awake" to hold a closed-lid Air
       running.

**Profiling & a11y (Xcode-tool-driven):**
 - [x] #14 Accessibility Inspector — Apple `performAccessibilityAudit`
       runs clean on Dashboard + Preferences via
       `AirAssistUITests/AccessibilityAuditTests`. Real issues fixed:
       NSHostingView root labels (`DashboardWindowController` +
       `PreferencesWindowController`), Picker accessibility labels
       (temperature unit, sort, stay-awake mode). SwiftUI framework-
       layout false-positives documented in `shouldSuppress(_:)` with
       per-case rationale (unlabeled layout containers, Picker AXPress
       vs AXIncrement). SensorCard `.green/.orange/.red` on
       `.regularMaterial` contrast (WCAG AA large-text 3:1 fail in
       light mode) deferred to v1.1 — locked visual design per #9/#10,
       breadcrumbed as `TODO_POST_LAUNCH` in `SensorCardView.swift`.
 - [x] #41 Keyboard nav — Esc-to-dismiss on Onboarding, `NSMainMenu`
       installed (⌘W / ⌘Q / ⌘, + Edit shortcuts), and
       `test_dashboardKeyboardReachesLabeledControls` confirms tab
       cycling reaches labeled controls.
 - [x] #48 TSan 30-min run — integration suite built with
       `-fsanitize=thread` (tsan dylib linked into AirAssist.app and
       AirAssistIntegrationRunner; verified via `otool -L`). Loop ran
       19 iterations (190 integration-test runs = 10 tests × 19) over
       30min 21s. **Zero TSan warnings, zero test failures.** Logs in
       `/tmp/airassist-tsan/` (not committed).
 - [x] #49 Leaks 1-hour run — sampled `leaks <pid>` every 5 min for
       60 min while driving 8-way churn (dashboard/prefs toggle,
       stay-awake cycle, seed/clear rules, pause) every 30s. Memory:
       30.7 MB → 41.5 MB (growth slowing toward plateau). Leaks:
       0 → 296 (28,416 bytes, ~0.5 KB/min). **ALL 296 leaks are
       Apple NSHostingView `_resetDragMarginsIfNeeded` → CGRegion
       framework bug — zero AirAssist frames in any leak stack.**
       Full write-up in `_inbox/leaks-1hr-findings.md` (gitignored,
       not committed).
 - [x] #49a Leaks regression gate — `scripts/regression/verify-leaks-budget.sh`
       builds fresh, drives 10-min 8-way churn, then hard-fails if any
       leak stack contains an `AirAssist` frame, leaked bytes > 15,000,
       or leak count > 150 (all 3× current baseline). Run before every
       `git tag vX.Y.Z`. Catches amplified NSHostingView regressions
       and any AirAssist-introduced leak.
 - [x] #60 Pre-launch audit pass (P0 + P1-1) — 2026-04-19.
       Full audit: `_inbox/pre-launch-audit-2026-04-19.md`. Landed:
       (a) ⌘⌥P hotkey discoverable in popover tooltip + General prefs
       toggle; (b) battery-aware mode toggle + preset pickers in General
       prefs; (c) status-item composite image a11y label ("Air Assist.
       CPU 84°C. Hot. Throttling active."); (d) a11y labels on threshold
       TextFields + SlotPicker pickers + popover pause menu; (e) pause-
       duration copy canonicalized to "15 minutes / 1 hour / 4 hours /
       Until quit" across popover, quick menu, and prefs; (f) ESC cancels
       the quit-while-rules-live confirm; (g) ⌘1–⌘4 switch Preferences
       tabs; (h) Help → Show Welcome… re-opens onboarding without
       clearing seen-version; (i) Help → Export Diagnostics… as a
       second entry point; (j) DiagnosticBundle now includes any
       AirAssist .ips / .crash reports from the last 7 days from
       ~/Library/Logs/DiagnosticReports. Build green.
 - [x] #49b RSS tripwire — `AirAssist/Services/MemoryWatchdog.swift`
       samples resident set size every 5 min via `mach_task_basic_info`
       and emits a single `Logger.warning` (subsystem
       `com.sjschillinger.airassist`, category `memory`) if RSS exceeds
       500 MB. Log-only, no telemetry, no UI. Wired into
       `AppDelegate.applicationDidFinishLaunching` / `applicationWillTerminate`.
 - [x] #50 Perf at 1000+ PIDs — `test_snapshotAt1000PIDs` spawns ~800
       extra children on top of setUp's 200, measures 5 snapshots at
       1722 PIDs: **25.19ms median** (samples 24.41 / 24.64 / 25.19 /
       25.39 / 26.81), 4× under the 100ms main-actor budget.

**Launch-day logistics (not code):**
 - [ ] #51 Pick one launch channel
 - [ ] Create public `homebrew-airassist` repo from template
 - [x] Replace `TODO_USER` placeholders everywhere — swept 2026-04-19,
       14 occurrences across 9 files (README, SECURITY, CONTRIBUTING,
       CHANGELOG, docs/releasing, ISSUE_TEMPLATE config, homebrew-tap
       template, release.yml) → `sjschillinger`.

**Explicitly deferred / accepted:**
 - #9 / #10 Icon and menu-bar legibility — accepted as shipping
 - #33 Notarization — declined (see #1), not pre-launch work
 - Broader governor/engine unit coverage beyond current safety paths

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
- [x] **#9 App icon** — accepted as shipping (owner call, 2026-04-18).
  Thermometer + air-flow metaphor on a blue→red gradient. No
  modernization pass planned for v1.0.
- [x] **#10 Menu bar icon legibility** — accepted as shipping
  (owner call, 2026-04-18). Light/dark screenshot pass deferred
  indefinitely; revisit only if a user reports it's unreadable.
- [x] **#11 First-launch experience** — `FirstLaunchSeeder` runs once
  after initial sensor discovery. Hides `CPU Die 5..N` + the `Other`
  category (PMIC/rails) by default; keeps SoC, GPU, Battery, Storage,
  CPU Die 1..4 visible. Governor stays **off** by default — throttling
  user processes without explicit opt-in would be a surprising
  default for an OSS utility.
- [x] **#12 Product name casing audit** — fixed HistoryView user-visible string
- [x] **#13 Empty states** — popover + dashboard sensor grid + "all disabled"
- [x] **#14 Accessibility Inspector pass** — Apple
  `performAccessibilityAudit` automated in
  `AirAssistUITests/AccessibilityAuditTests` (Dashboard + Preferences +
  keyboard smoke). All three tests green. Post-launch follow-up:
  SensorCard cool/warm/hot palette contrast (TODO_POST_LAUNCH in
  `SensorCardView.swift`).
- [x] **#15 Preferences + Dashboard window remember size/position** — fixed `center()` override

---

## 🛡️ Safety & correctness

- [x] **#16 Verify SIGSTOP actually lands on a real process** —
  automated: `test_16_SIGSTOPLands` seeds a rule, spawns `yes`, and
  asserts `ps -o stat=` hits state `T` within 5s. Runbook
  `verify-sigstop-lands.sh` retained for catastrophic cases the runner
  can't script.
- [x] **#17 SafetyCoordinator crash-recovery live test** —
  automated: `test_17_CrashRecoveryResumesOrphaned` SIGKILLs AirAssist
  mid-throttle and asserts the orphaned PID is SIGCONT'd on relaunch
  via the dead-man's-switch inflight file.
- [x] **#18 Sleep/wake cycle handling** —
  `SleepWakeObserver` listens on `NSWorkspace.shared.notificationCenter`
  for `.willSleep` / `.didWake`; policy is release-all on willSleep,
  let engines re-converge on next tick after didWake. Physically
  verified 2026-04-19: lid-close / wake cycle triggered
  `willSleep — releasing throttled PIDs` + `didWake — resuming
  engines` in os_log, and yes process was in state R post-wake.
- [x] **#19 PID reuse / process-exit mid-throttle** —
  `ProcessThrottler.installExitWatcher(pid:)` registers a kqueue
  `EVFILT_PROC NOTE_EXIT` source per throttled PID; releases the
  tracking entry on exit before the kernel can recycle the PID.
  Automated: `test_19_ExitWatcherReleasesPromptly` kills a throttled
  target externally and asserts the throttler drops it within 2s.
  Also flushed out a Swift 6 actor-isolation crash in the exit
  handler (commit 00c1087).
- [x] **#20 Thermal sensor read failure path** — `ReadState` enum + UI in popover & dashboard

---

## 📦 Release hygiene

- [x] **#21 Project file source of truth** — `project.yml` wins.
  `.xcodeproj` stays checked in so `git clone && open AirAssist.xcodeproj`
  works without XcodeGen, but CONTRIBUTING now explicitly documents
  that the pbxproj is generated output and must be kept in sync via
  `xcodegen generate`.
- [x] **#22 Real test coverage for core safety paths** — expanded this
  session with `ThrottleScheduleTests` (overnight-wrap + boundaries),
  `RuleTemplatesTests` (unique IDs / duty range / round-trip), and
  `ThresholdPresetTests` (warm < hot + monotonic Aggressive ≤ Balanced
  ≤ Conservative). Full suite green. Further governor/rule-engine
  coverage is a post-launch task (tracked under "Declined for now" in
  follow-ups, not ship-blocking).
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
- [x] **#33 Notarization dry-run with entitlement** — declined per #1
  (AGPL OSS trust model, Homebrew cask strips quarantine). Not a
  pre-launch item.

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

### Functional smoke tests — automated via `scripts/run-integration.sh`
- [x] **#34 Rule re-attach across app relaunch** —
  `test_34_RuleReattachAfterRelaunch` seeds a rule, terminates the
  app, relaunches, spawns a matching target, and asserts the engine
  re-attaches.
- [x] **#35 Pause auto-resume** — `test_35_PauseAutoResumes` (2s
  pause) + `test_35_ExplicitResumeClearsPause` (forever + resume).
- [x] **#36 Stay Awake assertion verification** —
  `test_36_StayAwakeSystemAssertionRegistersWithPMSet` and
  `test_36_StayAwakeDisplayAssertion` both shell out to
  `pmset -g assertions` and grep for the expected assertion type.
- [x] **#37 Lid-close with `displayThenSystem` mode** — timed
  downgrade automated via `test_37_DisplayThenSystemDowngrades`
  (~67s; uses the debug URL's 1-minute timer). Physical-hinge
  clamshell portion: runbook at
  `scripts/manual-tests/verify-lid-close-displaythensystem.sh`.
- [x] **#38 Force-quit mid-throttle cleanup** —
  `test_38_SIGTERMResumesInflight` seeds a rule, waits for throttle,
  SIGTERMs AirAssist, and asserts the target ends up in a non-T
  state (the sigaction handler SIGCONT'd it synchronously).

### UX polish (new since #11 landed)
- [x] **#39 Onboarding sheet on first launch** — `OnboardingWindow`
  presents once, gated by `onboarding.seenVersion`. Explains what the
  app does, the SIGSTOP safety model, picks threshold preset, offers
  rule-template toggles + optional hotkey / battery-aware checkboxes.
- [x] **#40 Tooltips on non-obvious controls** — `.help()` on Stay
  Awake mode variants, pause-duration buttons. (Broader pass across
  ThrottlingPrefsView / SensorsPrefsView is a nice-to-have; can land
  post-launch.)
- [x] **#41 Keyboard navigation in prefs** — Esc-to-dismiss on
  Onboarding, full `NSMainMenu` (⌘W / ⌘Q / ⌘, + Edit shortcuts),
  and `test_dashboardKeyboardReachesLabeledControls` asserting tab
  cycles reach non-empty labels.
- [x] **#42 Popover width at low sensor counts** — single-sensor summary
  mode tightened to 240pt (detailed stays at 260pt).

### Feature gaps worth closing pre-1.0
- [x] **#43 "Why is this throttled?" affordance** — each live-
  throttled row in the popover shows a source badge (governor / rule /
  manual) with a tooltip that lists all firing sources.
- [x] **#44 Right-click throttle adjust from popover** —
  `.contextMenu` on each throttled row: 85% / 50% / 25% quick sets,
  clear manual, release all.
- [x] **#45 Temperature history sparkline in popover** — 60-sample
  ring buffer in `ThermalStore.sparklineSamples`; GeometryReader +
  Path row in `MenuBarPopoverView` (no Charts dependency).
- [x] **#46 Export diagnostic bundle** — Preferences → Support →
  "Export Diagnostic Bundle…" stages system.txt / config.json
  (whitelisted UserDefaults) / live-state.json / thermal_history.ndjson
  / README.txt and zips via `/usr/bin/zip`. User-chosen save location.
- [x] **#47 Quit confirmation if rules are currently active** —
  `applicationShouldTerminate` shows an NSAlert if rules are live and
  PIDs are throttled (⌥ modifier bypasses the prompt).

### Stability (covers #22 but broader)
- [ ] **#48 Thread Sanitizer 30-min run** (runtime-only) — catch
  MainActor violations
- [ ] **#49 Instruments / Leaks 1-hour run** (runtime-only) — memory +
  handle growth
- [x] **#50 Perf at 1000+ PIDs** — `test_snapshotAt1000PIDs` in
  `ProcessInspectorPerfTests` spawns 800 extra `sleep 60` children on
  top of setUp's 200, measures 5 `ProcessInspector.snapshot()` samples
  at 1722 PIDs: **25.19ms median** (24.41 / 24.64 / 25.19 / 25.39 /
  26.81). Asserts median < 100ms — 4× under the main-actor budget.

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
- [x] **#54 Shortcuts.app actions (AppIntents)** —
  `PauseAirAssistIntent`, `ResumeAirAssistIntent`,
  `ThrottleFrontmostAppIntent`, wired up via
  `AirAssistShortcutsProvider`. All dispatch through the `airassist://`
  URL scheme for single-code-path testability.
- [x] **#55 Focus Filter integration** — `AirAssistFocusFilter`
  conforms to `SetFocusFilterIntent` (AppIntents, macOS 13+). Three
  actions user can bind per Focus: Do nothing, Pause AirAssist,
  Resume AirAssist. Like the other intents, dispatches via the
  `airassist://` URL scheme so there's one tested code path. Shows
  up under Settings → Focus → <focus> → Focus Filters once the app
  has been launched at least once.

### First-run / discoverability wins
- [x] **#56 Global pause hotkey** — `GlobalHotkeyService` uses Carbon
  `RegisterEventHotKey` for ⌘⌥P (avoids the Accessibility prompt
  `NSEvent.addGlobalMonitorForEvents` would trigger). Defaulted on;
  toggleable via `globalHotkey.enabled`.
- [x] **#57 Rule templates / starter library** — `RuleTemplates`
  catalogs Slack, Discord, Teams, Chrome Helper (Renderer/GPU), Edge
  Helper, Docker, Zoom, Dropbox, OneDrive with stable template IDs,
  conservative default duties, and rationale strings. Surfaced in the
  onboarding sheet.
- [x] **#58 Threshold presets** — `ThresholdPreset` enum with
  Conservative / Balanced / Aggressive; uniform-shift across
  categories preserves cross-category ordering. Surfaced in
  onboarding and covered by `ThresholdPresetTests`.

### Smart-default behaviors
- [x] **#59 Battery-aware auto-mode** — `BatteryAwareMode` listens on
  `IOPSNotificationCreateRunLoopSource` and swaps `ThresholdSettings`
  between on-battery and on-power presets (defaults: Aggressive on
  battery, Balanced plugged). Deliberately swaps *thresholds only*,
  not the governor preset — silent behavior changes surprise users
  more than silent display changes. Opt-in in onboarding.
- [x] **#60 Scheduled / time-windowed rules** — `ThrottleSchedule`
  (days + startMinute/endMinute) hangs off each `ThrottleRule`.
  `config.rule(for:now:)` gates on `schedule?.isActive(at:)`. Covers
  overnight-wrap semantics ("Friday 22:00 → Saturday 06:00"). 8
  dedicated unit tests for the isActive boundary/wrap branches.

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
