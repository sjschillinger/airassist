# AirAssist

A menu-bar thermal monitor and workload governor for the fanless MacBook
Air. Watches the SoC's internal thermal sensors, surfaces them in a tidy
dashboard, and — when things get warm — duty-cycles the greediest
user-owned processes so the Air can sustain its workload instead of
thermal-throttling into a slideshow.

No kernel extensions. No privileged helper. No fan control (the Air has
no fans). Everything AirAssist does, it does with the same permissions
your shell has.

> **Status:** pre-1.0. Works on my M2 Air. If you try it on different
> silicon, file an issue with the output of `sysctl hw.model` and what
> you saw.

> [!WARNING]
> **Use at your own risk.** Air Assist pauses and resumes running
> processes via POSIX signals (`SIGSTOP` / `SIGCONT`). That's a safe,
> documented Unix mechanism, but pausing the wrong process at the wrong
> time can still cause an application to stall, drop a connection, or
> in rare cases lose unsaved work. Review the throttle rules before
> enabling the governor, don't run Air Assist against processes you
> can't afford to pause, and keep backups. The software is provided
> AS IS, without warranty of any kind — see [LICENSE](LICENSE).

> **Not affiliated with Apple Inc.** "MacBook Air", "Mac", "macOS",
> and "Apple Silicon" are trademarks of Apple Inc. Air Assist is an
> independent open-source project and has no endorsement or
> affiliation with Apple.

## Features

- **Live thermal dashboard** — every HID thermal sensor the Air exposes,
  grouped by category (SoC, battery, ambient, PMIC), with sparkline
  history.
- **Menu bar readout** — configurable one- or two-slot layout (e.g.
  hottest temp + CPU%), with a heartbeat pulse when throttling is
  active.
- **Thermal governor** — as the hottest sensor climbs, caps CPU usage of
  non-foreground processes via SIGSTOP/SIGCONT duty cycling. Foreground
  app gets a floor so your current work stays responsive.
- **Throttle rules** — pin rules to specific processes ("never let
  `Xcode` exceed 60% CPU when SoC > 80°C"), with a daily counter of how
  often each fired.
- **One-shot manual throttle** — right-click menu: "Throttle frontmost
  for 60s."
- **Full history** — rolling per-sensor timeseries so you can spot
  patterns across days.

## Requirements

- macOS 15 Sequoia or later
- Apple Silicon (M1/M2/M3/M4). Intel Macs are not supported.
- Built for MacBook Air. Non-Air Macs work but some features are dimmed
  (see `NON_AIR_ROADMAP.md` in the development repo for what a proper
  Pro/Studio port would look like — not yet implemented).

### Why MacBook Air only?

The Air is the one Mac with no fans — when the SoC hits its thermal
limit, the only relief it has is to slow the CPU itself, and you watch
your machine stop feeling like a Mac. Every other Mac has spinning
metal that handles this case for you. AirAssist exists to give the
fanless Air an equivalent pressure-release valve: when temps climb,
throttle the background noise instead of the thing you're actually
doing.

It runs on Pros and Studios too — nothing is gated by model — but the
governor tuning is calibrated for the Air's thermal envelope, and the
value proposition is weaker on a machine that can just spin up a fan.
The [NON_AIR_ROADMAP.md](NON_AIR_ROADMAP.md) notes what a proper port
would entail if someone wants it.

## How this compares to other tools

AirAssist deliberately does **less** than the usual Mac tweaker apps.
That's the point: on a fanless machine you want *sustained workloads,
not control surfaces*. Quick differentiation by category:

| Tool category | What those tools do | What AirAssist does differently |
|---------------|---------------------|----------------------------------|
| **Fan-control utilities** | Read sensors, spin fans faster to clear heat. | The Air has no fans. AirAssist reads the same sensors but acts on *processes* — pausing the hottest background workloads instead of spinning metal that isn't there. |
| **Turbo-Boost togglers** | Disable the P-cores' turbo bin system-wide, usually via a kernel extension run as root. | User-privilege only. No kernel extension, no helper daemon. Pauses only processes your user owns, and per-app rather than disabling a whole CPU feature. |
| **Commercial per-app CPU cappers** | Set a static percentage cap on named apps. | Open source (AGPL-3.0), free for personal use, and *reactive* — the cap is driven by measured temperature, not a fixed number. Temps cool off, the cap lifts. |
| **`nice` / SIGSTOP loops in a shell** | One-off CLI niceness or hand-rolled pause/resume loops. | A well-behaved version of the same idea: dead-man's-switch resume on crash, 4 Hz stuck-cycle watchdog, sleep/wake handling, and a UI you can hand to someone who isn't a terminal user. |

**Shortest answer for HN / Reddit:** "It's the fanless-Mac equivalent
of fan control — when things get hot, it duty-cycles the greediest
background processes instead of spinning fans you don't have.
Open source, runs at user privilege, no kernel extension."

## Install

### Homebrew (recommended)

```bash
brew install --cask sjschillinger/airassist/airassist
```

No Xcode or developer tools required — Homebrew fetches a pre-built,
ad-hoc signed `.app` from the GitHub Releases page and drops it into
`/Applications`. Update with `brew upgrade --cask airassist`.

### Manual download

Grab the latest `AirAssist-<version>.zip` from the
[Releases](https://github.com/sjschillinger/airassist/releases) page,
unzip, and drag `AirAssist.app` into `/Applications`.

One extra step the first time: because the build is ad-hoc signed
rather than Developer-ID-signed, browsers add a quarantine flag that
triggers macOS's "damaged / can't be opened" dialog. Clear it once:

```bash
xattr -dr com.apple.quarantine /Applications/AirAssist.app
```

(Homebrew-installed copies skip this — `curl` doesn't set the
quarantine attribute.)

**Verify the download (optional but recommended.)** Each release
includes a `SHA256SUMS.txt` alongside the zip. Check the archive
against it before unzipping:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

### Updates

Air Assist checks GitHub's Releases API **once per day** for a new
version. When one exists, a "↑ Version X.Y.Z available" item appears
in the menu-bar right-click menu; clicking it opens the release page
so you can download the new zip (manual users) or run
`brew upgrade --cask airassist` (Homebrew users).

The check is a single request to `api.github.com`, with no analytics
and no other identifying data beyond a `User-Agent` header. You can
disable automatic checks in **Preferences → General → Updates**;
the "Check for Updates…" menu item still works manually.

Air Assist never downloads or installs binaries on its own — it only
surfaces the nudge. Actual upgrades happen through Homebrew or by
repeating the manual-download step.

## Build from source

```bash
git clone https://github.com/sjschillinger/airassist.git
cd airassist

# Project file is generated from project.yml via XcodeGen.
brew install xcodegen
xcodegen generate

open AirAssist.xcodeproj
```

Then build the `AirAssist` scheme. Unit tests live under
`AirAssistTests`; run them with `⌘U` or:

```bash
xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
           -destination 'platform=macOS' test
```

## How the throttling works

AirAssist uses `SIGSTOP` and `SIGCONT` on a duty cycle — e.g. "run 300ms,
pause 700ms" to cap a process at roughly 30% CPU. This is a standard
Unix technique for rate-limiting a process without a kernel extension;
it only works on processes your user owns, which is deliberate. AirAssist
will never ask for root and will never touch system daemons.

A `SafetyCoordinator` watches the throttling loop. It does three things:

- **Graceful quit** (⌘Q, Activity Monitor → Quit, OS shutdown): signal
  handlers for SIGTERM/SIGINT/SIGHUP/SIGQUIT send `SIGCONT` to every
  paused PID before the app exits.
- **Hard crash / SIGKILL**: on every throttle-set change, Air Assist
  writes the list of paused PIDs to a dead-man's-switch file at
  `~/Library/Application Support/AirAssist/inflight.json`. On the
  **next launch**, `recoverOnLaunch()` reads that file, sends `SIGCONT`
  to every PID in it, and deletes the file. macOS has no in-kernel
  mechanism to auto-resume children when a parent dies, so in the gap
  between a hard crash and the next launch, a paused process will
  stay paused — relaunching Air Assist clears it.
- **Stuck-cycle watchdog**: a 4Hz in-process timer force-sends
  `SIGCONT` to any PID that has been continuously stopped longer than
  500ms, protecting against a runaway duty-cycle bug.

If Air Assist is force-killed while processes are paused and you don't
want to relaunch, `kill -CONT <pid>` releases them manually.

## Privacy & network activity

Air Assist reads thermal and CPU data locally and keeps it on your
Mac. No analytics, no telemetry, no accounts.

The **only** outbound network call in normal operation is one request
per day to `api.github.com/repos/sjschillinger/airassist/releases/latest`
to check whether a newer version has been published. The request
carries a `User-Agent` of `AirAssist/<your-version>` (GitHub requires
a UA) and no other identifying data. You can turn it off entirely in
**Preferences → General → Updates**; the manual "Check for Updates…"
menu item still works when automatic checks are disabled.

No binary is ever downloaded or installed by the app itself — a
newer version just surfaces a menu nudge that opens the release page
in your browser. Confirm all of this for yourself with
`lsof -p $(pgrep AirAssist)` or Little Snitch.

## Sandboxing

Air Assist is **not** sandboxed. It uses the
`com.apple.security.temporary-exception.iokit-user-client-class`
entitlement to access `IOHIDEventSystemUserClient`, which is how it
reads the SoC's thermal sensors. That entitlement is incompatible with
the App Store sandbox, so Air Assist will not ship on the Mac App
Store.

Air Assist is distributed as an **ad-hoc signed** build via Homebrew
cask, and as source for anyone who wants to audit or build it
themselves. **It is not notarized by Apple, and that's a deliberate
choice, not a limitation.** Homebrew already handles Gatekeeper on
install, so notarization would add no real benefit — while locking the
"official" build identity to a single paid Apple Developer account and
raising the barrier for forks to ship their own builds. The source
tree plus the signed Homebrew tap is the trust root here; Apple's
vouching would be redundant. See [docs/releasing.md](docs/releasing.md)
for the full rationale and the release pipeline.

Throttling uses only POSIX signals on processes owned by your user
account. No kernel extension, no `SMAppService`-installed helper, no
elevated privileges at any point. If you're the kind of person who
reads entitlements files before installing something, check
`project.yml` — there is nothing else hiding in there.

## Support & response times

AirAssist is maintained by one person in spare time. Realistic
expectations so nobody feels ghosted:

- **Bug reports:** I aim to acknowledge within a week. A reproducer +
  a diagnostic bundle (Preferences → Support → Export Diagnostic
  Bundle…) dramatically shortens the round-trip.
- **Security issues:** see [SECURITY.md](SECURITY.md) for the private
  disclosure path; those get priority over feature requests.
- **Feature requests:** read, triaged on weekends, merged when they
  fit the fanless-Air thesis. "Make it also control fans" / "port to
  Windows" / "add a menu bar widget for Spotify" — politely declined.
- **Silent weeks happen.** If something looks stuck for more than two
  weeks, a gentle bump on the issue is welcome, not annoying.

## Contributing

Bug reports and PRs are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) for the build, test, and coding
guidelines. Security issues go through
[SECURITY.md](SECURITY.md), not public issues.

The short version:

```bash
./scripts/install-hooks.sh
xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
           -destination 'platform=macOS' test
```

## License

**AGPL-3.0** for non-commercial use.

| Use case | Allowed? |
|----------|----------|
| Personal / research / educational | Yes |
| Self-hosted / self-built (non-commercial) | Yes, with attribution |
| Fork and modify (non-commercial) | Yes — derivatives must stay AGPL-3.0 and share source |
| Commercial use / paid redistribution / rebranding | Requires a separate commercial license — contact the maintainer |

See [LICENSE](LICENSE) for the full terms.

Copyright (C) 2026 James Schillinger. All rights reserved.
