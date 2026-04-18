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

- macOS 14 or later
- Apple Silicon (M1/M2/M3/M4). Intel Macs are not supported.
- Built for MacBook Air. Non-Air Macs work but some features are dimmed
  (see `NON_AIR_ROADMAP.md` in the development repo for what a proper
  Pro/Studio port would look like — not yet implemented).

## Install

### Homebrew (recommended)

```bash
brew install --cask TODO_USER/airassist/airassist
```

No Xcode or developer tools required — Homebrew fetches a pre-built,
ad-hoc signed `.app` from the GitHub Releases page and drops it into
`/Applications`. Update with `brew upgrade --cask airassist`.

### Manual download

Grab the latest `AirAssist-<version>.zip` from the
[Releases](https://github.com/TODO_USER/airassist/releases) page,
unzip, and drag `AirAssist.app` into `/Applications`.

One extra step the first time: because the build is ad-hoc signed
rather than Developer-ID-signed, browsers add a quarantine flag that
triggers macOS's "damaged / can't be opened" dialog. Clear it once:

```bash
xattr -dr com.apple.quarantine /Applications/AirAssist.app
```

(Homebrew-installed copies skip this — `curl` doesn't set the
quarantine attribute.)

Updates are delivered via [Sparkle](https://sparkle-project.org/);
AirAssist will check for new versions weekly.

## Build from source

```bash
git clone https://github.com/TODO_USER/airassist.git
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

A `SafetyCoordinator` watches the throttling loop. If AirAssist crashes
or is force-quit, any paused process receives `SIGCONT` at the OS level
when its parent exits, so nothing stays frozen.

## Privacy & network activity

Air Assist reads thermal and CPU data locally and keeps it on your
Mac. No analytics, no telemetry, no accounts.

The app makes **one** kind of outgoing request: a periodic HTTPS fetch
of the Sparkle appcast (`SUFeedURL` in `Info.plist`) to check for
updates. You can disable update checks entirely in Preferences → General
if you'd rather update manually. No other network I/O happens anywhere
in the codebase — feel free to confirm with `lsof -p $(pgrep AirAssist)`
or a tool like Little Snitch.

## Sandboxing

Air Assist is **not** sandboxed. It uses the
`com.apple.security.temporary-exception.iokit-user-client-class`
entitlement to access `IOHIDEventSystemUserClient`, which is how it
reads the SoC's thermal sensors. That entitlement is incompatible with
the App Store sandbox, so Air Assist will not ship on the Mac App
Store — it's distributed only as a signed, notarized Developer ID
build (and as source, for anyone who wants to audit or build it
themselves).

Throttling uses only POSIX signals on processes owned by your user
account. No kernel extension, no `SMAppService`-installed helper, no
elevated privileges at any point. If you're the kind of person who
reads entitlements files before installing something, check
`project.yml` — there is nothing else hiding in there.

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

[MIT](LICENSE).
