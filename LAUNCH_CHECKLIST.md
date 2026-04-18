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

- [ ] **#1 Signing & notarization infrastructure**
  - Enroll in Apple Developer Program ($99/yr)
  - Obtain Developer ID Application cert + App Store Connect API key
  - Fill signing/notarization TODOs in `.github/workflows/release.yml`
  - Dry-run `notarytool submit` on a throwaway build before tagging 1.0

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

- [x] **#6 Natural sort for sensor names** — committed 618ca3f
- [ ] **#7 Category order in popover**
  - Currently alphabetical-ish (CPU, GPU, SoC, Battery, Storage, Other)
  - On M-series with 14 CPU Die entries, SoC is off-screen
  - Proposed order: SoC → CPU → GPU → Battery → Storage → Other
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
- [ ] **#12 Product name casing audit**
  - `CFBundleName: Air Assist`, `CFBundleIdentifier: com.airAssist.app`
  - Grep UI strings for "AirAssist" vs "Air Assist" inconsistency
- [ ] **#13 Empty states**
  - All sensors disabled → dashboard blank rectangle?
  - No throttled PIDs → live-throttle list empty state
  - Walk every screen in a freshly-installed app
- [ ] **#14 Accessibility Inspector pass**
  - Run Xcode Accessibility Inspector on dashboard + popover + prefs
  - Every control must have a label; verify VoiceOver flow end-to-end
- [ ] **#15 Preferences window remembers size/position**
  - Check `PreferencesWindowController` for `windowFrameAutosaveName`

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
- [ ] **#20 Thermal sensor read failure path**
  - If IOHIDEventSystemClient returns empty, show "Sensors unavailable" state
  - Not a blank grid

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
- [ ] **#23 CHANGELOG.md + v0.1.0 release notes**
  - Sparkle appcasts reference release notes; need a conventions doc
- [ ] **#24 GitHub issue + PR templates**
  - `.github/ISSUE_TEMPLATE/bug_report.md`
  - `.github/ISSUE_TEMPLATE/feature_request.md`
  - `.github/pull_request_template.md`
  - Bug template must ask for `sysctl hw.model` + macOS version
- [ ] **#25 SECURITY.md**
  - Contact method for responsible disclosure
  - Tool that SIGSTOPs processes will draw security research attention
- [ ] **#26 CODE_OF_CONDUCT.md** (Contributor Covenant boilerplate)
- [ ] **#27 CONTRIBUTING.md**
  - Expand current README one-liner: test commands, project regen,
    commit-message style, branch strategy
- [ ] **#28 Strip `DEVELOPMENT_TEAM` from `project.yml` before publish**
  - Verify not leaking personal team ID

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
- [ ] **#32 Sandboxing decision — document explicitly**
  - README: "AirAssist is not sandboxed because IOHIDEventSystemClient
    requires a temporary-exception entitlement"
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

## Completed

- ✅ Phase 1 scaffolding (commit `cbb0d7c`): `.gitignore`, References/
  untracked, pre-commit hook, publish.sh, CI workflows, LICENSE, README.
- ✅ Natural sensor sort (commit `618ca3f`).
