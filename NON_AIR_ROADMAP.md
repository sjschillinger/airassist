# Non-Air Mac Support — Roadmap

Everything needed to make AirAssist a first-class app for fan'd Apple
Silicon Macs (MacBook Pro 14/16, Mac mini, Mac Studio, Mac Pro, iMac),
not just fanless Airs. **Recorded for reference, not scheduled.**

## Guiding principle

Most features should *auto-expand* on non-Air hardware rather than
requiring a mode switch. Detect the chassis once at launch, stash a
`HardwareProfile`, and gate UI / heuristics on its flags. Users on Airs
should never see controls that don't apply; users on Pros should
never have to opt in to features their hardware supports.

---

## Tier 1 — Easy, no new entitlements, ~1–2 days total

### 1. `HardwareProfile` detection (~30 min)

- Detect via `sysctlbyname("hw.model")` → e.g. `"Mac15,7"` (MBP 14" M3),
  `"Mac14,2"` (MBA 15" M2).
- Map to a `ChassisClass` enum: `.air`, `.proLaptop`, `.mini`, `.studio`,
  `.iMac`, `.macPro`, `.unknown`.
- Store on `ThermalStore` as a `let hardware: HardwareProfile`.
- Expose capability flags:
  - `hasFans: Bool`
  - `expectedFanCount: Int`
  - `supportsHighPowerMode: Bool` (16" M1/M3/M4 Max only)
  - `hasProMotionDisplay: Bool` (for future per-refresh features)
  - `typicalSustainedThrottleTempC: Double` (Air ≈ 85, Pro ≈ 95, Studio ≈ 90)
- Add a `HardwareProfileTests` target with fixture strings for every
  Apple Silicon identifier shipped so far.

**File shape:**
```
AirAssist/Services/HardwareProfile.swift
AirAssistTests/HardwareProfileTests.swift
```

### 2. Fan RPM read-out as first-class sensors (~half day)

- SMC keys `F0Ac`, `F1Ac` (actual RPM), `F0Mn`, `F0Mx` (min/max RPM),
  `F0Tg` (target RPM). Reachable through the same IOKit path we
  already use — no new entitlements.
- Introduce `FanSensor` alongside `Sensor`, or add a `.fan` case to
  `SensorCategory`. Probably cleanest: keep `Sensor` as-is, add a
  `unit: SensorUnit` enum (`.celsius`, `.rpm`, `.percent`) so the
  existing dashboard grid and menu bar slots render fans for free.
- Dashboard sort order gets a new tint for fans (e.g. blue, not thermal
  red/green).
- Menu bar slots — allow "Fan 1 RPM" as a slot value.
- Only enumerate fans when `hardware.hasFans`.

### 3. Pro-specific sensor labelling (~2h)

- MBPs expose more thermocouples (GPU die, battery inlet, chassis).
  Our HID scan already picks them up — they just show as
  "Unknown" / raw names.
- Build a chassis-aware label map (`"TG0P"` → "GPU Die" on Pro,
  skip on Air where it doesn't exist).
- Move `SensorCategory` inference from name-pattern matching to the
  label map where possible.

### 4. Chassis-specific governor presets (~half day)

- Add a static `GovernorPreset.recommended(for: HardwareProfile) -> GovernorPreset`.
- Air defaults stay where they are.
- Pro presets should be *looser* — don't start capping until 92–95°C
  because fans are the first line of defence. The current 80°C Air
  default would make a Pro cap during perfectly normal sustained
  workloads.
- Studio/Mac Pro: even looser — these are desktops with serious cooling;
  capping at 85°C would cripple them during legitimate rendering work.
- First-launch logic: pick the preset by `hardware.chassisClass` unless
  the user has already saved a custom config.

### 5. "Let fans handle it" governor mode (~1 day)

- New `GovernorMode` case: `.fanFirst` (visible only when `hardware.hasFans`).
- Semantics: don't apply CPU throttling until fans have been at ≥80% of
  their max RPM for N seconds AND temp is still climbing. Gives Pros
  their normal aggressive performance until the fans have actually
  tried and failed.
- Requires fan RPM reads from Tier 1 #2, so sequence after that.
- UI: toggle in the Governor prefs tab, gated on `hardware.hasFans`.

### 6. High Power Mode awareness (~1h)

- `NSProcessInfo.isLowPowerModeEnabled` already works as a detector.
- There's no public API to *toggle* High Power Mode (it's a System
  Settings toggle, 16" Pro Max only).
- When detected AND `hardware.supportsHighPowerMode`, show a banner:
  "High Power Mode is on — the governor has raised its temperature cap
  to match." Auto-adjust `maxTempC` by +5°C for as long as it's on.
- Observe changes via the `NSProcessInfoPowerStateDidChange` notification.

---

## Tier 2 — Medium, still no privileged helper

### 7. Per-fan curve visualisation (~1 day)

- Read-only graph in a new "Fans" prefs tab: X-axis time, Y-axis RPM,
  overlaid with hottest sensor temp.
- Lets users *see* whether the fans are keeping up. Pairs nicely with
  the "Let fans handle it" mode — you can tell when the mode would
  have kicked in.
- Only present when `hardware.hasFans`.

### 8. Chassis-aware menu bar icon layouts (~half day)

- On fan'd Macs, allow a three-slot layout: temp + CPU% + fan RPM.
- On Airs, keep the current one/two-slot layouts and hide the
  three-slot option in prefs.
- `MenuBarIconRenderer` extension: a new `width` constant + a
  `drawThreeSlot` primitive.

### 9. Wider thermal history graph on desktops (~half day)

- On Studios / Mac Pros / iMacs the app likely runs indefinitely on
  AC power; rolling-window history can be longer.
- `HistoryLogger` already prunes old entries — make the retention
  window a function of `hardware.chassisClass` (Air: 24h, Pro: 72h,
  Desktop: 7d).

---

## Tier 3 — Hard, privileged helper territory

User has confirmed MAS distribution is not a constraint, so this is on
the table — but the work is real. Queue behind Tiers 1 and 2.

### 10. SMAppService privileged helper (~1 week of plumbing)

- Separate Xcode target: `AirAssistHelper` (command-line tool).
- Signing: the helper's `SMAuthorizedClients` must list the main app's
  designated requirement; the main app's `SMPrivilegedExecutables`
  must list the helper's. Both need to match exactly or the install
  silently fails.
- `Info.plist` for the helper declares its `MachServices` name
  (`com.airAssist.helper`). The main app opens an `NSXPCConnection`
  to that service.
- One-time user prompt on first launch: "Air Assist wants to install
  a helper to control system fans." Standard macOS auth dialog.
- Update path: helper lives in `/Library/LaunchDaemons/`. Updates via
  Sparkle need to re-register the helper if the bundle version
  changes — tricky, needs testing.
- Revocation: a "Remove helper" button in prefs that calls
  `SMAppService.unregister()` cleanly.

### 11. Fan write / custom curves (~half week after helper lands)

- SMC write keys: `F0Md` (manual/auto mode flag), `F0Tg` (target RPM),
  `F0Mx` (forced max cap).
- Helper exposes an XPC interface: `setFanTarget(index: Int, rpm: Int,
  mode: FanMode)`.
- UI: per-fan curve editor in the Fans prefs tab — map sensor temp to
  fan RPM with draggable points.
- Safety: helper must refuse fan targets below `F0Mn` (can cook the
  chassis) and above `F0Mx` (can damage bearings). Dead-man's switch
  analogous to our `SafetyCoordinator`: if the helper loses its XPC
  client for >30s, restore fans to auto.

### 12. System daemon throttling (~half week after helper lands)

- Specific allowlist, not a blanket "throttle anything" capability.
  Start with user-requested offenders:
  - `mds` (root, Spotlight metadata indexer)
  - `mds_stores` (_spotlight, Spotlight content scanner)
  - `backupd` (root, Time Machine)
- **Hardcoded blocklist** of anything that would wedge the system if
  paused, must be enforced by the helper itself so the main app can't
  bypass it:
  - `launchd`, `kernel_task`, `WindowServer`, `cfprefsd`,
    `loginwindow`, `coreaudiod`, `UserEventAgent`, `bluetoothd`,
    `opendirectoryd`, `configd`, `distnoted`, `mDNSResponder`,
    `syslogd`, `securityd`, `trustd`.
- UI phrasing: "Throttle these additional system processes" with
  checkboxes for the allowlist, NOT a generic "throttle any process"
  picker. Framing matters — we're helping users target known
  offenders, not handing them a loaded gun.
- Same `SafetyCoordinator`-style dead-man's switch, but for helper
  crashes: if helper dies with a root process paused, a launchd
  watchdog must SIGCONT everything the helper was managing.

### 13. Protected-entitlement fallback detection (~1 day)

- Some Apple processes (Music, Safari, sometimes Mail) refuse SIGSTOP
  even from root due to `com.apple.security.cs.restrict-signals`
  entitlement.
- When the helper sees `EPERM` on a root-privileged kill, surface it
  to the UI: mark that PID as "Protected by system, can't throttle."
- Prevents the user from blaming us for not throttling something that
  Apple has explicitly forbidden.

---

## Tier 4 — Nice-to-haves, post-helper

### 14. Per-app power-mode suggestions (~1 day)

- Detect when a game/pro-app is frontmost on a 16" Pro Max and prompt:
  "Switch to High Power Mode?" (can't toggle it for the user, but can
  guide them).
- Needs a small app-classification table (Blender, Final Cut, games).

### 15. Chassis-specific sparkline tints (~2h)

- Thermal headroom is chassis-relative. On a Studio, 80°C is "idle-ish";
  on an Air, 80°C is "concerning." The sparkline's warm/hot thresholds
  should shift with `hardware.typicalSustainedThrottleTempC`.

### 16. Fan curve library (~2 days)

- Built-in named curves: "Silent" (fans low until 85°C), "Balanced"
  (current Apple-like behaviour), "Aggressive" (fans ramp at 65°C to
  prefer temp over noise).
- Requires fan write (item #11) and some per-chassis curve validation.

---

## Testing & validation concerns

- **Every tier-3 item needs hardware-in-the-loop testing.** Apple Silicon
  fan and SMC behaviour is model-specific and not all of it is
  documented. Budget test time on every supported chassis class, not
  just "it worked on my M3 Pro."
- **The helper dead-man's switch is the single most important piece of
  code we'd write.** If it works, worst-case is a confusing user
  experience. If it doesn't, worst-case is a root process pinned to
  SIGSTOP surviving our crash, which needs a reboot to recover.
- **Sparkle + privileged helper** is a known friction point. Budget a
  day just for update-path testing. Other signed/notarized menu-bar
  utilities solve this, but the integration takes time to get right.

---

## Decision points we'd need to revisit

1. **Do we ship a universal build or separate Air/Pro bundles?** My
   vote: universal with runtime detection. Simpler for users, easier
   for us to release.
2. **Does "non-Air support" mean renaming the app?** "Air Assist" is a
   charming Air-specific name. If we're serious about Pros, consider
   whether the brand needs to evolve (e.g. "Mac Assist," "Thermal
   Assist") — but that's a marketing decision, not a technical one.
3. **Mac App Store: permanently ruled out?** Tier 3 kills MAS
   distribution. Confirm this is still fine before building the
   helper.

---

## Sequencing recommendation, whenever we pick this up

1. **Tier 1, all of it** — delivers 80% of non-Air value with zero
   risk. Do this first and ship it even if we never do Tier 3.
2. **Tier 2** — polish on top of Tier 1.
3. **Tier 3 items 10 + 11** — helper + fan write together, since the
   helper's main justification is fan control. System-daemon
   throttling (#12) is a separate, later decision.
4. **Tier 4** — only after Tier 3 is stable in the wild for a few
   weeks of beta.

Total calendar estimate if pursued linearly with active testing on
real hardware: **~3–4 weeks of focused work** for Tiers 1 + 2 + core
of Tier 3 (helper + fan control, no system-daemon support).
