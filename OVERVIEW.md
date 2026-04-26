# Air Assist — What It Does

A plain-English tour of every feature in Air Assist 0.9.0. For install
instructions, see the [README](README.md). For the technical roadmap and
change history, see [CHANGELOG.md](CHANGELOG.md).

---

## In one sentence

Air Assist is a menu-bar app that watches your Mac's temperatures and,
when you let it, pauses runaway processes before your machine gets too
hot to use — built primarily for fanless Apple Silicon MacBooks (Air,
Neo) where heat has nowhere to go.

## Who it's for

- **Fanless Apple Silicon MacBooks** (MacBook Air, MacBook Neo) — the
  primary target. The SoC has no fan, so sustained load either forces
  macOS to self-throttle the whole machine or cooks the battery over
  time. Air Assist intervenes before either happens.
- **MacBook Pros** — works fine, just less dramatic gains. Useful if you
  care about battery longevity or want fine-grained per-app caps.
- **Mac mini / Studio / iMac** — runs, but these are not the design
  target. No harm in trying.
- **Requires:** Apple Silicon (arm64) and macOS Sequoia 15 or newer.

---

## The features

### Live thermal dashboard

Every HID thermal sensor your Mac exposes, grouped by category:

- **SoC** — the processor package and its subcomponents
- **Battery** — cell and pack temps
- **Ambient** — chassis-level sensors
- **PMIC** — power management IC temps

Each sensor gets a sparkline showing recent history so you can see
trends, not just instantaneous values. The menu-bar readout can show
one or two slots (hottest temp and/or total CPU%), with a heartbeat
pulse when throttling is active.

If `IOHIDEventSystemClient` returns no readings after a few seconds (it
happens — macOS version + hardware combos vary), the app surfaces
"Sensors unavailable" instead of hiding an empty list.

### Workload governor (opt-in)

When enabled, the governor watches the hottest sensor and the total
user CPU%. When either crosses a cap you set, it finds the processes
using the most CPU and duty-cycles them — briefly pausing them
(SIGSTOP), then resuming (SIGCONT), faster or slower depending on how
far over the cap you are.

Key protections:

- **Off by default.** Nothing happens unless you turn it on.
- **Foreground-app floor.** The app you're actively using is never
  allowed to drop below a minimum responsiveness you set, so your
  current work stays smooth.
- **User-owned processes only.** The app cannot and will not touch
  system daemons, other users' processes, or anything requiring root.
- **"Throttle only on battery"** option — keeps caps armed-but-silent
  when plugged in, so your desk workflow stays snappy and the governor
  only kicks in when it actually matters for battery and heat.
- **OS thermal-state awareness.** When macOS itself reports thermal
  pressure, the governor biases toward firmer throttling so it catches
  runaway heat before the SoC self-throttles the whole machine.

### Per-app throttle rules

Pin a CPU cap to a specific app. Examples:

- *"Never let `Xcode` exceed 60% CPU when SoC > 80°C."*
- *"Always cap `zoom.us` at 40% on battery."*
- *"Kill `Spotlight` down to 10% during a Zoom call."*

Each rule has a daily fire counter and a "why this fired" trace, so
you can see whether your rules are actually doing anything useful or
whether they're overkill.

### Stay Awake (caffeinate-style)

Four modes, pick from the menu bar or Preferences:

1. **Off** — default.
2. **Keep system awake (allow display sleep)** — good for downloads,
   background renders on battery.
3. **Keep system & display awake** — for presentations, long watches.
4. **Display on, then system only** — display stays lit for N minutes,
   then the screen can sleep while work continues. Useful for
   unattended jobs.

A "Release Stay Awake when the display sleeps" opt-in is available if
you want the assertion to drop on lid close / screen lock / idle
display-off, and re-take on wake. Off by default — the default behaves
like the `caffeinate(1)` command.

### One-shot manual throttle

Right-click the menu bar icon → "Throttle frontmost app at 30%." For
when a specific app is misbehaving and you just want to tame it for a
minute. No rule needed, no configuration.

### Global hotkey

**⌘⌥P** toggles pause/resume from anywhere. Implemented via Carbon
event hooks, so Air Assist does **not** need Accessibility permission.

### URL scheme — `airassist://`

Scriptable from Shortcuts.app, Raycast, Alfred, or the shell:

```bash
open airassist://pause?duration=30s
open airassist://resume
open airassist://throttle-frontmost?duty=40%
```

Full format documented in the README.

### Pause throttling

Quick escape hatch when you want to turn Air Assist off temporarily
without changing your configuration. Pause for 15 min, 1 hour, 4
hours, or until quit. The popover shows when it will resume.

### Diagnostic bundle export

Help → Export Diagnostics… produces a redacted zip with logs, thermal
history, rule fire counters, and captured MetricKit diagnostic reports
(crashes, hangs, CPU exceptions). Suitable for attaching to a bug
report without leaking anything private.

### Update notifier (opt-out)

Once a day, Air Assist checks the GitHub Releases API for a newer tag.
If one exists, a small nudge appears in the menu-bar right-click menu
— clicking it opens the release page. **No binary replacement, no
installer, no telemetry.** Disable in Preferences → Updates.

### First-run risk disclosure

The first time you launch Air Assist, a one-time modal explains what
the governor can do (pause your processes), that it's off by default,
and that you've accepted AGPL-3.0 terms. This is idempotent and
versioned — if a future version adds capabilities that warrant another
pass, the disclosure runs again for that change, not at random.

### Quit confirmation

If any rules are actively throttling when you press ⌘Q, Air Assist
asks before releasing the paused PIDs — so you don't accidentally
un-pause a render farm mid-job. Suppressed with ⌥⌘Q if you want the
old "quit immediately" behavior.

---

## Safety infrastructure

The things you only notice when something goes wrong:

- **Rescue LaunchAgent** — a tiny helper that releases any lingering
  paused PIDs if the main app crashes or is force-killed. No root, no
  kernel extension, no helper daemon with special privileges.
- **Signal handlers** — SIGTERM, SIGINT, SIGHUP, SIGQUIT all trigger a
  graceful cleanup: SIGCONT every paused PID before the process exits.
- **Inflight dead-man's-switch file** — if Air Assist crashes mid-pause,
  the next launch reads the file and resumes those PIDs, so you
  don't need to hunt for stuck processes yourself.
- **Watchdog** — 4Hz background check that force-SIGCONTs any PID that
  has been stopped longer than 500ms for any reason. Belt and braces.
- **MetricKit integration** — crashes, hangs, and CPU exceptions are
  captured in structured JSON and stored locally, ready for diagnostic
  bundle export.
- **Memory tripwire** — the app flags and logs a diagnostic if its own
  RSS crosses 500 MB, so a runaway leak can't snowball silently.

---

## Privacy & trust

- **No telemetry.** The app makes one HTTP request — the daily Releases
  API check — and you can turn that off.
- **No network otherwise.** No crash-reporting service, no analytics,
  no phone-home.
- **No root.** The app operates at user privilege only.
- **Public APIs only.** Reads from `IOHIDEventSystemClient`, the same
  interface `powermetrics(1)` uses. Does not call any private Apple
  SPI. Does not touch SMC. Ships no bundled binary blob.
- **Sandboxing tradeoff:** intentionally not sandboxed, because process
  inspection (`proc_listpids` / `kill(pid, 0)` for PID liveness checks)
  requires non-sandboxed access. Justified at length in the source.

You can verify all of this by reading the code — that's the entire
point of the AGPL-3.0 stance.

---

## License

**AGPL-3.0-or-later.** Anyone can use Air Assist — personal, internal,
or commercial — as long as derivatives stay AGPL and source is shared
with users (including over-the-network use, which is the clause that
distinguishes AGPL from plain GPL).

A separate commercial license is available from the author for parties
who want to redistribute or embed Air Assist without AGPL's copyleft
obligations. It's an option for people who can't comply with AGPL, not
a paywall on commercial use.

---

## How to get it

```bash
brew install --cask sjschillinger/airassist/airassist
```

Then launch from Launchpad or Spotlight. The menu bar icon appears in
the top-right corner.

- **Source + issues:** https://github.com/sjschillinger/airassist
- **Releases:** https://github.com/sjschillinger/airassist/releases
- **Homebrew tap:** https://github.com/sjschillinger/homebrew-airassist
