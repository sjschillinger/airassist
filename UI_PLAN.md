# AirAssist — UI Improvement Plan

Saved 2026-04-18. Reference for phased UI work on top of the shipped
throttling/governor engines.

---

## Problems with the current UI

1. **Preferences has 6 tabs and they're not orthogonal.**
   - `Thresholds` and `Sensors` are both "sensor config."
   - `App Rules` and `Governor` are both "throttling config."
   - `Display` is really "menu bar config."
2. **The headline feature (Governor) is buried.** 6th tab, and the
   dashboard only reveals it as a thin footer that appears *only when
   something's actively being throttled*. No reassurance that the
   governor is even armed.
3. **The menu bar popover is temperature-only.** Doesn't mention CPU,
   top processes, or governor state.
4. **Adding an app rule is friction-heavy.** Preferences → App Rules
   → "Add Rule…" sheet → scroll every process → slider → confirm.
5. **Sliders have no frame of reference.** "Max temp 85°C" is
   meaningless without knowing current values.
6. **No "gaming mode" — shut-up-for-an-hour.** Requires toggling
   rules off *and* setting governor to Off across two tabs.
7. **Menu bar icon doesn't differentiate "armed" from "actively
   throttling."**
8. **Sensor cards are static** — just number + color, no trend.

---

## Target information architecture

### Preferences: 6 → 4 tabs

| Tab | Icon | Contents |
|---|---|---|
| **General** | `gearshape` | Launch at login, dock icon, update interval, **global "Pause throttling" switch** |
| **Menu Bar** (rename from Display) | `menubar.rectangle` | Slot pickers (unchanged) |
| **Sensors** | `thermometer.medium` | Merged Sensors + Thresholds: enable toggles plus per-category warm/hot thresholds, "Reset thresholds" button |
| **Throttling** | `gauge.with.dots.needle.67percent` | Merged Governor + App Rules on the same page |

Rationale: users think of "throttling" as one concept, not two engines.

### Dashboard: three bands

```
┌────────────────────────────────────────────────────────┐
│ Hot: CPU 84°C · Total CPU 220% · Governor: Armed       │  summary chips (always visible)
├───────────────────────────┬────────────────────────────┤
│   Sensor cards            │ TOP CPU                    │
│   (existing grid)         │  Xcode      118%  [+]      │
│                           │  Electron    72%  [+]      │
│                           │  yes         30%  ⚠ 30%    │  already throttled
└───────────────────────────┴────────────────────────────┘
```

- Summary band always visible.
- Top CPU panel replaces the only-when-active footer.
- `[+]` opens a tiny inline editor, not a modal sheet.

### Menu bar popover: add throttling section

```
Air Assist                      [⏸ Pause]
───────────────
CPU              PCP      67°C
GPU                       58°C
...
───────────────
Governor: Throttling 2 apps  ⚠
 • Chrome Helper   40%
 • Electron        30%
───────────────
Dashboard…
Preferences…
Quit
```

### Menu bar icon state

- **Armed / idle**: icon unchanged.
- **Actively throttling**: small orange dot overlay.
- **Cap breach climbing**: red dot.

---

## Priority-ordered change list

### Tier 1 — highest impact, modest effort
1. **Merge Preferences tabs** 6 → 4.
2. **Governor presets** — Gentle / Balanced / Aggressive dropdown.
3. **Slider reference ticks** — "idle ≈ 62°C · now 84°C" hints.
4. **Global Pause throttling** switch (1h / 4h / until next launch).
5. **Dashboard Top CPU panel** with `[+]` → inline rule creation.

### Tier 2 — polish
6. Governor summary chips, always visible on dashboard.
7. Menu bar icon throttle indicator (dot overlay).
8. Popover governor mini-section.
9. "Reset thresholds to defaults" button.
10. Per-rule live CPU% indicator.

### Tier 3 — nice-to-have
11. Sensor card sparklines (last 60s).
12. Empty-state rule suggestions (Chrome Helper / Electron etc.).
13. Right-click menu bar menu with fast paths.
14. Symbol-effect pulse on cards crossing into "hot."
15. Keyboard shortcuts (⌘1–4 tabs, ⌘D dashboard).

### Tier 4 — separable future work
16. History graph tab (HistoryLogger exists already).
17. Export logs / report-a-hot-streak.
18. Smart rule suggestions (sustained high-CPU auto-detect).

---

## Execution plan — three passes

- **Pass 1 — info architecture** (half day): tabs 6→4, popover
  throttling section, summary chips, global pause. No new business
  logic — surfaces the features we already have.
- **Pass 2 — decision support** (half day): presets, slider reference
  ticks, dashboard top-CPU panel with one-click rule, menu bar icon
  badge.
- **Pass 3 — delight** (later): sparklines, empty-state suggestions,
  keyboard shortcuts, history graph.
