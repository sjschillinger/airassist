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

## 🚨 Blocks launch (must fix before public release)

- [~] **#1 Signing & notarization infrastructure** — free-tier path landed
  - ✅ Free-tier release pipeline: ad-hoc signed zip via Homebrew cask
    (`.github/workflows/release.yml` + `scripts/homebrew-tap-template/` +
    `docs/releasing.md`). Draft-only; nothing publishes without a manual
    click.
  - [ ] Decision: stay on free tier for 0.1.0, or enroll in Apple
    Developer Program ($99/yr) and switch to Developer ID + notarization
    before 1.0. Upgrade path is a single workflow edit (see the comment
    block at the top of `release.yml`).
  - [ ] Still-pending if we stay free-tier: create the separate
    `homebrew-airassist` public repo from `scripts/homebrew-tap-template/`.

- [ ] **#2 Sparkle framework not actually linked**
  - `SUFeedURL`/`SUPublicEDKey` are declared but Sparkle is absent from `project.yml`
  - Decision: link Sparkle + host appcast, OR strip placeholder keys until ready
  - If linking: generate Ed25519 keypair, add to build, host appcast.xml

- [ ] **#3 Final bundle identifier**
  - Currently `com.airAssist.app` — pick final reverse-DNS before notarization
  - Candidates: `com.github.sjschillinger.airassist`, `app.airassist`, domain-tied

- [ ] **#4 Hard-coded `airassist.app` domain in Info.plist**
  - `SUFeedURL = https://airassist.app/appcast.xml` — do we own it?
  - Alternatives: GitHub Pages appcast (`sjschillinger.github.io/airassist/appcast.xml`),
    GitHub Releases direct

- [ ] **#5 Privacy statement vs. auto-update**
  - README says "does not phone home" but Sparkle will fetch appcast
  - Resolve: add 1-line "network activity" section to README

---

## 🧹 Ship-blocking polish

- [x] **#6 Natural sort for sensor names** — 618ca3f
- [x] **#7 Category order in popover** — reordered enum (SoC first)
- [ ] **#8 Condense 14× "CPU Die N" rows**
  - Default collapsed to hottest die + expand affordance
  - Or aggregate "CPU Cluster (hottest of N)" synthetic row
- [ ] **#9 App icon quality check**
  - Inspect current `.appiconset` PNGs against Big Sur/Sonoma design lang
  - If placeholder, commission real icon before launch
- [ ] **#10 Menu bar icon legibility (light + dark menu bar)**
  - Screenshot on light wallpaper + dark wallpaper
  - Pulse minAlpha 0.35 may wash out on light bars
- [ ] **#11 First-launch experience**
  - Either onboarding sheet, or sensible defaults that make first 5s useful
  - At minimum: pre-select best 2 sensors, default governor to "armed"
- [x] **#12 Product name casing audit** — fixed HistoryView user-visible string
- [x] **#13 Empty states** — popover + dashboard sensor grid + "all disabled"
- [ ] **#14 Accessibility Inspector pass**
  - Run Xcode Accessibility Inspector on dashboard + popover + prefs
  - Every control must have a label; verify VoiceOver flow end-to-end
- [x] **#15 Preferences + Dashboard window remember size/position** — fixed `center()` override

---

## 🛡️ Safety & correctness

- [ ] **#16 Verify SIGSTOP actually lands on a real process**
  - `yes > /dev/null &` → add rule → `ps -o pid,stat,comm` → expect `T`
  - Pending since multi-session ago. Do before launch.
- [ ] **#17 SafetyCoordinator crash-recovery live test**
  - Start throttling → `kill -9` AirAssist → verify target resumes
  - Single most important behavior; if broken, launch is bad
- [ ] **#18 Sleep/wake cycle handling**
  - Observe `NSWorkspace.willSleepNotification`/`didWakeNotification`
  - Decide: resume all throttled PIDs on sleep? Re-arm on wake?
- [ ] **#19 PID reuse / process-exit mid-throttle**
  - Detect stale PIDs (kqueue EVFILT_PROC on NOTE_EXIT, or poll)
  - Don't send SIGSTOP to recycled PIDs
- [x] **#20 Thermal sensor read failure path** — `ReadState` enum + UI in popover & dashboard

---

## 📦 Release hygiene

- [ ] **#21 Project file source of truth**
  - Both `project.yml` + `.xcodeproj` tracked
  - Pick one: if XcodeGen wins, remove `.xcodeproj` from publish allowlist,
    add generate step to README. If pbxproj wins, delete `project.yml`.
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

- [ ] **#29 Name / trademark check**
  - "Air Assist" is an HVAC term + laser-cutter feature
  - USPTO TESS search before public launch; have fallback name ready
  - Candidates if blocked: "Thermal Assist", "Mac Assist", "Aerial", "Breeze"
- [ ] **#30 Fanless-only positioning — have the HN answer ready**
  - README is honest; write 1-liner: "yes, works on Pros; not optimized yet;
    roadmap in NON_AIR_ROADMAP.md (dev repo)"
- [ ] **#31 Competitor comparison blurb**
  - Pre-write the "how is this different" answer for HN/Reddit
  - Lean into: "less, but free, OSS, no root"
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

## Active gameplan (as of 2026-04-18)

Infrastructure is done. Free-tier release pipeline is live (ad-hoc
signed zip → draft release → Homebrew cask). Everything below is what
stands between us and tagging 0.1.0.

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

### Nice-to-have (can slip to 0.1.1)
- #8 condense CPU Die rows
- #18 sleep/wake handling
- #19 PID reuse / process-exit mid-throttle
- #22 real test coverage for safety-critical paths

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

## Completed

- ✅ Phase 1 scaffolding (commit `cbb0d7c`): `.gitignore`, References/
  untracked, pre-commit hook, publish.sh, CI workflows, LICENSE, README.
- ✅ Natural sensor sort (commit `618ca3f`).
- ✅ Stay Awake + launch checklist (commit `4338654`).
- ✅ Quick-win batch (12 items: #7, #12, #13, #15, #20, #23–#28, #32).
- ✅ Free-tier distribution pipeline (ad-hoc signed Homebrew cask):
  rewrote `release.yml`, added `scripts/homebrew-tap-template/`,
  wrote `docs/releasing.md`, updated README install section.
