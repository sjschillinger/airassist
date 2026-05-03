import SwiftUI
import AppKit
import Darwin
import os

struct MenuBarPopoverView: View {
    let store: ThermalStore
    var onDashboard: () -> Void    = {}
    var onPreferences: () -> Void  = {}
    var onQuit: () -> Void         = {}

    @AppStorage("tempUnit") private var tempUnitRaw: Int = TempUnit.celsius.rawValue
    private var unit: TempUnit { TempUnit(rawValue: tempUnitRaw) ?? .celsius }

    @AppStorage("sensorDisplayMode") private var displayModeRaw: String = SensorDisplayMode.detailed.rawValue
    private var displayMode: SensorDisplayMode {
        SensorDisplayMode(rawValue: displayModeRaw) ?? .detailed
    }

    /// Last non-off governor mode the user had selected. Used by the
    /// master toggle in `controlsSection` so flipping the governor off
    /// then back on restores their previous mode rather than always
    /// landing on `.both`. Stored as the raw string of `GovernorMode`.
    @AppStorage("governor.lastActiveMode") private var lastActiveGovernorModeRaw: String = GovernorMode.both.rawValue

    /// Live prefs for the "Throttle frontmost" quick button. Edited in
    /// Preferences → Throttling → Frontmost-app quick throttle. Read
    /// each click so a slider change applies immediately.
    @AppStorage("throttleFrontmost.duty") private var frontmostDuty: Double = 0.30
    @AppStorage("throttleFrontmost.durationMinutes") private var frontmostDurationMinutes: Int = 60

    /// Tick used to refresh manual-throttle countdowns once per second
    /// while the popover is visible. The popover only renders while
    /// open, so this is a cheap timer that costs nothing the rest of
    /// the time.
    @State private var countdownTick: Date = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Phase 2 of the visibility sprint: each customizable
            // section is gated behind PopoverSectionPrefs. Order
            // stays fixed in code for now; Phase 5 adds the
            // user-facing Preferences UI to flip these. Defaults =
            // every section visible, so this changes nothing for
            // existing users.
            if PopoverSectionPrefs.isVisible(.sensors) {
                sensorList
                sparklineRow
                Divider()
            }
            if PopoverSectionPrefs.isVisible(.cpuActivity) {
                cpuActivitySection      // includes own trailing Divider
            }
            if PopoverSectionPrefs.isVisible(.manualThrottles) {
                manualThrottlesSection  // includes own trailing Divider
            }
            if PopoverSectionPrefs.isVisible(.governorStatus) {
                throttleSection
                Divider()
            }
            if PopoverSectionPrefs.isVisible(.controls) {
                controlsSection
                Divider()
            }
            actionButtons
        }
        .onReceive(countdownTimer) { countdownTick = $0 }
        // #42 Tighten width. Previously fixed at 280; summary-mode popovers
        // felt oversized for a single-sensor readout. 260 is the width the
        // category headers + throttle rows were actually designed against.
        .frame(width: displayMode == .summary ? 240 : 260)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            // Template imageset → SwiftUI renders in the current foreground
            // style, so this automatically flips with light/dark appearance.
            Image("MenuBarGlyph")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)   // decorative; "Air Assist" text speaks
            Text(AppStrings.appName)
                .font(.headline)
            Spacer()
            pauseMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var pauseMenu: some View {
        Menu {
            if store.isPauseActive {
                Button("Resume now") { store.resumeThrottling() }
            } else {
                Section("Pause throttling for") {
                    Button("15 minutes") { store.pauseThrottling(for: 15 * 60) }
                    Button("1 hour")     { store.pauseThrottling(for: 60 * 60) }
                    Button("4 hours")    { store.pauseThrottling(for: 4 * 60 * 60) }
                    Button("Until quit") { store.pauseThrottling(for: nil) }
                }
                if GlobalHotkeyService.shared.isEnabled {
                    Divider()
                    Text("Global hotkey: ⌘⌥P")
                }
            }
        } label: {
            Image(systemName: store.isPauseActive ? "pause.circle.fill" : "pause.circle")
                .foregroundStyle(store.isPauseActive ? .yellow : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(hotkeyTooltip)
        // Label voices state; hint voices the affordance. VoiceOver
        // already announces "menu" via the trait, so we don't say it.
        .accessibilityLabel(store.isPauseActive ? "Throttling paused" : "Pause throttling")
        .accessibilityHint(store.isPauseActive
                           ? "Activate to resume immediately"
                           : "Activate to choose a pause duration")
    }

    /// Combined tooltip for the pause menu: state + hotkey when enabled.
    /// Surfaces ⌘⌥P without requiring a Preferences trip (#P0-1).
    private var hotkeyTooltip: String {
        let state = store.isPauseActive ? "Throttling paused" : "Pause throttling"
        if GlobalHotkeyService.shared.isEnabled {
            return state + " (⌘⌥P)"
        }
        return state
    }

    @ViewBuilder
    private var sensorList: some View {
        let groups = store.sensorsByCategory
        if groups.isEmpty {
            switch store.sensorService.readState {
            case .booting:
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading sensors…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            case .unavailable:
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Sensors unavailable")
                        .font(.caption).bold()
                    Text("macOS didn't return any thermal sensors. Re-launch Air Assist, and if it persists, check Preferences → Sensors for details.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            case .ok:
                EmptyView()   // won't hit — groups wouldn't be empty
            }
        } else {
            switch displayMode {
            case .detailed:
                SensorListView(groups: groups,
                               thresholds: store.thresholds,
                               unit: unit)
                    .frame(maxHeight: 260)
            case .summary:
                SensorSummaryView(groups: groups,
                                  thresholds: store.thresholds,
                                  unit: unit)
            }
        }
    }

    /// One row per *unique process name*, with a (×N) suffix when multiple PIDs
    /// share a name. Dead PIDs are filtered via `kill(pid, 0)` — SafetyCoordinator
    /// only drains stale entries on a full rule-off, so a process that exited
    /// mid-throttle can linger in `liveThrottledPIDs` until then; hiding it here
    /// keeps the popover honest without touching the safety-critical state.
    private struct ThrottleRow: Identifiable {
        let id: String        // the name, used as ForEach identity
        let name: String
        let duty: Double      // lowest (most aggressive) duty in the group
        let count: Int
        /// Union of ThrottleSources across the PIDs in this group — used by
        /// #43 (why is this throttled?) to show a source badge and a tooltip.
        let sources: Set<ThrottleSource>
        /// All PIDs in this group — used by #44 to issue per-source releases
        /// from a context menu.
        let pids: [pid_t]
    }

    private var throttleRows: [ThrottleRow] {
        // Pull the richer detail view so we can attribute sources per-PID,
        // and still do the kill(pid, 0) liveness filter.
        let detail = store.processThrottler.throttleDetail
            .filter { kill($0.pid, 0) == 0 }
        let grouped = Dictionary(grouping: detail, by: { $0.name })
        return grouped.map { name, items in
            let srcs = Set(items.flatMap { $0.sources.keys })
            let dutyMin = items
                .flatMap { $0.sources.values }
                .min() ?? 1.0
            return ThrottleRow(
                id: name,
                name: name,
                duty: dutyMin,
                count: items.count,
                sources: srcs,
                pids: items.map { $0.pid }
            )
        }
        .sorted { $0.duty < $1.duty }
    }

    /// Human-readable explanation used by the row tooltip and the
    /// context menu header (#43).
    private func sourcesDescription(_ sources: Set<ThrottleSource>) -> String {
        let labels = sources.map { src -> String in
            switch src {
            case .rule:     return "per-app rule"
            case .governor: return "system governor"
            case .manual:   return "manual throttle"
            }
        }
        .sorted()
        if labels.isEmpty { return "unknown source" }
        if labels.count == 1 { return "Throttled by \(labels[0])." }
        return "Throttled by " + labels.prefix(labels.count - 1).joined(separator: ", ")
            + " and " + labels.last! + "."
    }

    private func sourceBadge(_ sources: Set<ThrottleSource>) -> (symbol: String, tint: Color) {
        if sources.contains(.governor) { return ("thermometer.high", .orange) }
        if sources.contains(.rule)     { return ("list.bullet.rectangle", .blue) }
        if sources.contains(.manual)   { return ("hand.point.up.left", .purple) }
        return ("circle", .secondary)
    }

    /// Compact one-minute hottest-temp sparkline (#45). Only rendered when
    /// we have at least 4 samples — less than that is visually meaningless.
    /// Draws inline, no expensive off-screen passes.
    @ViewBuilder
    private var sparklineRow: some View {
        let samples = store.sparklineSamples
        if samples.count >= 4 {
            HStack(spacing: 8) {
                Text("Last min")
                    .font(.caption2).foregroundStyle(.secondary)
                Sparkline(samples: samples)
                    .frame(height: 18)
                    .frame(maxWidth: .infinity)
                if let last = samples.last {
                    Text(unit.format(last))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            // VoiceOver: pure-Path sparkline has no inherent label. Speak the
            // first/last/peak as a one-line summary so non-sighted users get
            // the trend without seeing the line.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sparklineA11yLabel(samples))
        }
    }

    /// Trend summary read aloud in place of the silent Path drawing.
    /// Kept short — VoiceOver users navigating the popover don't want
    /// a paragraph here, just the orientation.
    private func sparklineA11yLabel(_ samples: [Double]) -> String {
        guard let first = samples.first, let last = samples.last,
              let peak = samples.max() else { return "" }
        return "Hottest sensor trend: now \(unit.format(last)), was \(unit.format(first)) one minute ago, peaked at \(unit.format(peak))."
    }

    // MARK: - CPU Activity (v0.14 — visibility sprint phase 1)

    /// Live "what's running hot right now" panel. Reads from the
    /// governor's already-1Hz process snapshot, so this is free —
    /// no new polling, no new state. Shows the top 5 processes by
    /// CPU% after filtering out anything already covered by another
    /// section (rules, manual throttles) so we don't double-count.
    ///
    /// Right-click on any row gets the user the same actions they'd
    /// otherwise have to dig through the dashboard for: throttle
    /// now, add a rule, protect via never-throttle, jump to
    /// Activity Monitor.
    @ViewBuilder
    private var cpuActivitySection: some View {
        let rows = cpuActivityRows
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cpu").foregroundStyle(.blue)
                Text("CPU Activity").font(.caption).bold()
                Spacer()
                if !rows.isEmpty {
                    Text("\(rows.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if rows.isEmpty {
                // Friendly empty state — happens when nothing's above
                // the visibility floor (>1% CPU, not user-managed).
                Text("Nothing notable. Your Mac is idle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { p in
                    cpuActivityRow(p)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.04))
        Divider()
    }

    /// Top processes the CPU activity panel shows. The selection
    /// rules — visibility floor, exclude rule-managed, exclude
    /// manually throttled, exclude self, sort, take prefix — live
    /// in `CPUActivityFilter` so they're unit-testable without a
    /// store. See that file for the rationale per filter.
    private var cpuActivityRows: [RunningProcess] {
        let manuallyThrottled: Set<pid_t> = Set(
            store.processThrottler.throttleDetail
                .filter { $0.sources[.manual] != nil }
                .map(\.pid)
        )
        return CPUActivityFilter.topRows(
            from: store.governor.lastTopProcesses,
            ruleManagedPIDs: Set(store.ruleEngine.managedPIDs),
            manuallyThrottledPIDs: manuallyThrottled,
            selfPID: getpid()
        )
    }

    @ViewBuilder
    private func cpuActivityRow(_ p: RunningProcess) -> some View {
        HStack(spacing: 6) {
            Text(p.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(Int(p.cpuPercent.rounded()))%")
                .monospacedDigit()
                .foregroundStyle(CPUTint.color(p.cpuPercent))
        }
        .font(.caption2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.displayName), \(Int(p.cpuPercent.rounded())) percent CPU")
        .accessibilityHint("Right click for throttle and rule options")
        .contextMenu {
            // Default duty matches the existing frontmost-throttle
            // user preference so this menu and the popover's
            // "Throttle [frontmost]" button behave the same way for
            // the same user. Hardcoded duration of 1h matches the
            // Throttle Frontmost intent default.
            Button("Throttle now (\(Int(frontmostDuty * 100))% for 1 hour)") {
                store.throttleFrontmost(
                    pid: p.id,
                    name: p.name,
                    duty: frontmostDuty,
                    duration: 60 * 60
                )
            }
            Button("Add throttle rule (\(Int(frontmostDuty * 100))% cap)") {
                store.upsertRule(for: p, duty: frontmostDuty)
            }
            Button("Add \"\(p.name)\" to Never-Throttle list") {
                NeverThrottleList.add(p.name)
            }
            Divider()
            Button("Show in Activity Monitor") {
                Self.openActivityMonitor()
            }
            Button("Copy process name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.name, forType: .string)
            }
        }
    }

    /// CPU% color tier — see `CPUTint` for the palette + rationale.

    // MARK: - Manual throttles strip (v0.10)

    /// Rows for any PIDs currently running under a `.manual` cap.
    /// These are the apps the user threw under the bus via the
    /// "Throttle [frontmost]" button, the right-click quick menu, or
    /// the URL scheme. Surfaced separately from the main throttle
    /// list so the user always knows exactly what they put down.
    private struct ManualThrottleRow: Identifiable {
        let id: pid_t
        let pid: pid_t
        let name: String
        let duty: Double
        let deadline: Date?
    }

    private var manualThrottleRows: [ManualThrottleRow] {
        store.processThrottler.throttleDetail
            .filter { $0.sources[.manual] != nil && kill($0.pid, 0) == 0 }
            .map { d in
                ManualThrottleRow(
                    id: d.pid,
                    pid: d.pid,
                    name: d.name,
                    duty: d.sources[.manual] ?? 1.0,
                    deadline: store.manualThrottleDeadline(pid: d.pid)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Read `countdownTick` so SwiftUI re-evaluates when the timer
    /// fires. The value itself is only the trigger.
    private func manualThrottleA11yLabel(_ row: ManualThrottleRow) -> String {
        let pct = Int((row.duty * 100).rounded())
        var s = "\(row.name), capped at \(pct) percent"
        if let r = remainingLabel(for: row.deadline) { s += ", \(r)" }
        return s
    }

    private func remainingLabel(for deadline: Date?) -> String? {
        guard let deadline else { return nil }
        _ = countdownTick
        let secs = Int(deadline.timeIntervalSinceNow.rounded())
        if secs <= 0 { return "0s" }
        if secs < 60 { return "\(secs)s left" }
        let m = secs / 60
        if m < 60 { return "\(m)m left" }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h)h left" : "\(h)h \(rm)m left"
    }

    @ViewBuilder
    private var manualThrottlesSection: some View {
        let rows = manualThrottleRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left.fill")
                        .foregroundStyle(.purple)
                    Text("Quick throttles")
                        .font(.caption).bold()
                    Spacer()
                    Text("\(rows.count) active")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(Int((row.duty * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                        if let label = remainingLabel(for: row.deadline) {
                            Text("· \(label)")
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            store.releaseManualThrottle(pid: row.pid)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Release this manual throttle now.")
                        .accessibilityLabel("Release manual throttle for \(row.name)")
                    }
                    .font(.caption2)
                    // Combine the row so VoiceOver reads name + duty + remaining
                    // as a single unit, then exposes the release button as its
                    // own actionable child.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(manualThrottleA11yLabel(row))
                    .contextMenu {
                        Button("Show in Activity Monitor") {
                            Self.openActivityMonitor()
                        }
                        Button("Add \"\(row.name)\" to Never-Throttle list") {
                            NeverThrottleList.add(row.name)
                            store.releaseManualThrottle(pid: row.pid)
                        }
                        Divider()
                        Button("Copy process name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.name, forType: .string)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.purple.opacity(0.06))
            Divider()
        }
    }

    @ViewBuilder
    private var throttleSection: some View {
        let rows = throttleRows
        let totalLive = rows.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: governorIcon).foregroundStyle(governorColor)
                Text(governorSummary).font(.caption).bold()
                Spacer()
                if totalLive > 0 {
                    Text("\(totalLive) active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // Surface the governor's "why" string — otherwise states that
            // don't flip a throttling flag (e.g. on-battery-only gate firing
            // on AC) look identical to a generic "armed" and the user can't
            // tell the toggle did anything.
            if !governorReasonLine.isEmpty {
                Text(governorReasonLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !rows.isEmpty {
                ForEach(rows.prefix(3)) { row in
                    let badge = sourceBadge(row.sources)
                    HStack(spacing: 6) {
                        // Source badge (#43). Tooltip explains which engine
                        // asked for the throttle, so the user isn't left
                        // guessing why Chrome suddenly got quieter.
                        Image(systemName: badge.symbol)
                            .foregroundStyle(badge.tint)
                            .help(sourcesDescription(row.sources))
                            .accessibilityHidden(true)   // covered by the row's combined label
                        Text(row.count > 1 ? "\(row.name) (×\(row.count))" : row.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int((row.duty * 100).rounded()))%").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .contentShape(Rectangle())
                    .help(sourcesDescription(row.sources))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(throttleRowA11yLabel(row))
                    // #44 Right-click / long-press context menu to adjust
                    // or release this app's throttle without opening prefs.
                    .contextMenu {
                        Section(sourcesDescription(row.sources)) {
                            Button("Set to 85% (light)") { setManualDuty(row: row, duty: 0.85) }
                            Button("Set to 50%")          { setManualDuty(row: row, duty: 0.50) }
                            Button("Set to 25% (heavy)")  { setManualDuty(row: row, duty: 0.25) }
                            Divider()
                            if row.sources.contains(.manual) {
                                Button("Clear manual throttle") {
                                    for pid in row.pids {
                                        store.processThrottler.clearDuty(source: .manual, for: pid)
                                    }
                                }
                            }
                            Button("Release all throttling for this app") {
                                for pid in row.pids {
                                    store.processThrottler.release(pid: pid)
                                }
                            }
                        }
                    }
                }
                if rows.count > 3 {
                    Text("+ \(rows.count - 3) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Apply (or replace) a manual-source duty on every PID in the row.
    /// Used by the #44 context-menu quick adjustments.
    private func throttleRowA11yLabel(_ row: ThrottleRow) -> String {
        let pct = Int((row.duty * 100).rounded())
        let nameWithCount = row.count > 1 ? "\(row.name), \(row.count) processes" : row.name
        return "\(nameWithCount), capped at \(pct) percent. \(sourcesDescription(row.sources))"
    }

    private func setManualDuty(row: ThrottleRow, duty: Double) {
        for pid in row.pids {
            store.processThrottler.setDuty(duty, for: pid, name: row.name, source: .manual)
        }
    }

    private var governorSummary: String {
        if store.isPauseActive {
            if let until = store.pausedUntil, until != .distantFuture {
                return "Paused · resumes \(relative(to: until))"
            }
            return "Paused"
        }
        if store.governorConfig.isOff && !store.throttleRules.enabled {
            return "Throttling: Off"
        }
        if store.governor.isTempThrottling || store.governor.isCPUThrottling {
            return "Governor active"
        }
        // On-battery-only gate firing on AC — governor is armed but
        // deliberately silent. Flag it in the summary so the toggle has a
        // visible effect.
        if store.governorConfig.onBatteryOnly
            && store.governor.reason.hasPrefix("Idle · on AC") {
            return "Governor idle (on AC)"
        }
        if !store.liveThrottledPIDs.isEmpty {
            return "Rules active"
        }
        return "Governor armed"
    }

    /// Secondary line under the summary: the governor's own plain-language
    /// reason string. Hidden when empty / off / paused (the summary already
    /// covers those).
    private var governorReasonLine: String {
        if store.isPauseActive { return "" }
        if store.governorConfig.isOff { return "" }
        return store.governor.reason
    }
    private var governorColor: Color {
        if store.isPauseActive { return .yellow }
        if store.governorConfig.isOff && !store.throttleRules.enabled { return .secondary }
        if store.governor.isTempThrottling || store.governor.isCPUThrottling { return .orange }
        return .green
    }
    private var governorIcon: String {
        if store.isPauseActive { return "pause.circle.fill" }
        if store.governor.isTempThrottling { return "thermometer.high" }
        if store.governor.isCPUThrottling { return "cpu" }
        return "gauge.with.dots.needle.67percent"
    }

    private func relative(to date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Controls section (v0.10)

    /// Quick controls: governor master toggle, on-battery-only gate,
    /// throttle the frontmost app, and the Stay Awake mode picker.
    /// One control per row — at 260px wide, two-up toggles wrap their
    /// labels and the section feels disorganized. Vertical rhythm
    /// matches the action buttons below.
    private var controlsSection: some View {
        VStack(spacing: 0) {
            // Governor master toggle.
            controlRow(icon: "gauge.with.dots.needle.67percent",
                       label: "Governor",
                       help: "Enable or disable the system-wide thermal/CPU governor.") {
                Toggle("", isOn: governorEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            // On-battery-only gate (sub-control of the governor).
            controlRow(icon: "battery.75percent",
                       label: "Only on battery",
                       indent: true,
                       help: "Only act while on battery; armed-but-silent on AC.") {
                Toggle("", isOn: Binding(
                    get: { store.governorConfig.onBatteryOnly },
                    set: { store.governorConfig.onBatteryOnly = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(store.governorConfig.isOff)
            }

            // Throttle frontmost — toggles. If the frontmost app is
            // already manually throttled, click clears it. Otherwise
            // applies the user-configured duty for the user-configured
            // duration (or indefinitely if duration == -1).
            Button(action: toggleFrontmostThrottle) {
                rowContent(icon: isFrontmostManuallyThrottled
                                 ? "hand.raised.slash"
                                 : "hand.point.up.left",
                           iconTint: isFrontmostManuallyThrottled ? .purple : nil,
                           label: throttleFrontmostLabel,
                           indent: false) {
                    Text(isFrontmostManuallyThrottled
                         ? "Release"
                         : "\(Int((frontmostDuty * 100).rounded()))%")
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canThrottleFrontmost)
            .help(throttleFrontmostHelp)
            .modifier(HoverHighlight())

            // Stay Awake quick picker.
            controlRow(icon: store.stayAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                       iconTint: store.stayAwake.isActive ? .yellow : nil,
                       label: "Stay Awake",
                       help: "Keep the Mac awake — system, display, or with a timeout.") {
                stayAwakeMenu
            }

            // Scenario preset — one-click profiles. Bundles governor
            // mode, caps, on-battery flag, and stay-awake mode.
            controlRow(icon: "wand.and.stars",
                       label: "Scenario",
                       help: "Apply a one-click preset (Presenting / Lap / Cool / Performance / Auto).") {
                scenarioMenu
            }
        }
        .padding(.vertical, 4)
    }

    private var scenarioMenu: some View {
        Menu {
            ForEach(ScenarioPreset.allCases) { preset in
                Button {
                    store.applyScenario(preset)
                } label: {
                    Label(preset.label, systemImage: preset.sfSymbol)
                }
                .help(preset.tagline)
            }
        } label: {
            Text("Apply…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Apply scenario preset")
    }

    /// Standard row for a control whose trailing widget is a Toggle/Menu.
    /// Mirrors `MenuBarButton`'s padding so toggles and buttons share a
    /// vertical rhythm.
    @ViewBuilder
    private func controlRow<Trailing: View>(
        icon: String,
        iconTint: Color? = nil,
        label: String,
        indent: Bool = false,
        help: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        rowContent(icon: icon, iconTint: iconTint, label: label, indent: indent, trailing: trailing)
            .help(help ?? "")
    }

    /// Shared row layout — icon + label on the left, trailing widget on
    /// the right. Used by both the toggle rows and the throttle-frontmost
    /// button so they line up pixel-for-pixel.
    @ViewBuilder
    private func rowContent<Trailing: View>(
        icon: String,
        iconTint: Color? = nil,
        label: String,
        indent: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            if indent { Spacer().frame(width: 14) }
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(iconTint ?? .primary)
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            trailing()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Master governor toggle. Off → `.off`. On → restore last non-off
    /// mode (defaults to `.both` on first run). Writing back to
    /// `governorConfig` triggers the persistence + governor.updateConfig
    /// chain in the store's didSet.
    private var governorEnabledBinding: Binding<Bool> {
        Binding(
            get: { !store.governorConfig.isOff },
            set: { newOn in
                if newOn {
                    let restored = GovernorMode(rawValue: lastActiveGovernorModeRaw) ?? .both
                    store.governorConfig.mode = (restored == .off) ? .both : restored
                } else {
                    if !store.governorConfig.isOff {
                        lastActiveGovernorModeRaw = store.governorConfig.mode.rawValue
                    }
                    store.governorConfig.mode = .off
                }
            }
        )
    }

    /// Frontmost-app snapshot, captured by `MenuBarController` *before*
    /// the popover steals focus. A live `NSWorkspace.frontmost…` query
    /// from inside the view would return Air Assist (because the
    /// popover's `makeKey()` activates us), so the button has to use
    /// this captured value. `nil` when the popover was opened with
    /// nothing else frontmost (e.g. cold launch).
    private var frontmost: ThermalStore.FrontmostSnapshot? {
        store.capturedFrontmost
    }
    private var canThrottleFrontmost: Bool { frontmost != nil }

    /// True when the captured frontmost app currently has any
    /// manual-source duty applied. Drives the icon swap and the
    /// click-to-release path.
    private var isFrontmostManuallyThrottled: Bool {
        guard let pid = frontmost?.pid else { return false }
        return store.processThrottler.throttleDetail
            .first { $0.pid == pid }?
            .sources.keys.contains(.manual) ?? false
    }

    private var throttleFrontmostLabel: String {
        guard let name = frontmost?.name else { return "Throttle frontmost" }
        return isFrontmostManuallyThrottled ? "Release \(name)" : "Throttle \(name)"
    }

    private var throttleFrontmostHelp: String {
        if isFrontmostManuallyThrottled {
            return "Release the manual cap on this app."
        }
        let pct = Int((frontmostDuty * 100).rounded())
        let dur: String = {
            if frontmostDurationMinutes < 0 { return "until you clear it" }
            if frontmostDurationMinutes >= 60 {
                let h = frontmostDurationMinutes / 60
                return "for \(h) hour\(h > 1 ? "s" : "")"
            }
            return "for \(frontmostDurationMinutes) minutes"
        }()
        return "Cap the frontmost app at \(pct)% \(dur). Adjust in Preferences → Throttling."
    }

    /// Click handler. Throttles or releases depending on current state.
    private func toggleFrontmostThrottle() {
        let log = os.Logger(subsystem: "com.sjschillinger.airassist", category: "QuickThrottle")
        guard let app = frontmost else {
            log.error("toggleFrontmostThrottle: frontmost is nil — capturedFrontmost was not set")
            return
        }
        log.notice("toggleFrontmostThrottle pid=\(app.pid) name=\(app.name) duty=\(frontmostDuty) alreadyThrottled=\(isFrontmostManuallyThrottled)")
        if isFrontmostManuallyThrottled {
            store.releaseManualThrottle(pid: app.pid)
            return
        }
        // -1 sentinel from the duration picker = "until I clear it".
        // Pass a very long duration so the auto-release effectively
        // never fires; the user releases via the same button.
        let duration: TimeInterval = frontmostDurationMinutes < 0
            ? 60 * 60 * 24 * 365   // 1 year
            : TimeInterval(frontmostDurationMinutes * 60)
        store.throttleFrontmost(
            pid: app.pid,
            name: app.name,
            duty: frontmostDuty,
            duration: duration
        )
    }

    /// Stay Awake mode picker. Mirrors the right-click quick menu but
    /// lives in the popover so single-click users can reach it. The
    /// display-timeout variant uses the user's saved minutes preference
    /// (defaults to 10) so it's a one-click toggle, not a fresh decision.
    private var stayAwakeMenu: some View {
        Menu {
            Button(action: { store.setStayAwakeMode(.off) }) {
                Label("Off", systemImage: store.stayAwake.currentMode == .off ? "checkmark" : "")
            }
            Button(action: { store.setStayAwakeMode(.system) }) {
                Label("Keep system awake (allow display sleep)",
                      systemImage: store.stayAwake.currentMode == .system ? "checkmark" : "")
            }
            Button(action: { store.setStayAwakeMode(.display) }) {
                Label("Keep system & display awake",
                      systemImage: store.stayAwake.currentMode == .display ? "checkmark" : "")
            }
            let mins = stayAwakeTimeoutMinutes
            let timeoutMode = StayAwakeService.Mode.displayThenSystem(minutes: mins)
            Button(action: { store.setStayAwakeMode(timeoutMode) }) {
                Label("Display on \(mins) min, then system only",
                      systemImage: store.stayAwake.currentMode == timeoutMode ? "checkmark" : "")
            }
            if let remaining = store.stayAwake.displayTimerRemaining, remaining > 0 {
                Divider()
                let m = Int(remaining / 60)
                let s = Int(remaining.truncatingRemainder(dividingBy: 60))
                Text(String(format: "Display sleeps in %d:%02d", m, s))
            }
        } label: {
            Text(stayAwakeShortLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Stay Awake mode: \(stayAwakeShortLabel)")
    }

    /// Short one-word-ish label for the menu's collapsed state — full
    /// `menuLabel` is too long for a 260px-wide popover row.
    private var stayAwakeShortLabel: String {
        switch store.stayAwake.currentMode {
        case .off:                           return "Off"
        case .system:                        return "System"
        case .display:                       return "System & display"
        case .displayThenSystem(let m):      return "\(m) min then system"
        }
    }

    private var stayAwakeTimeoutMinutes: Int {
        let m = UserDefaults.standard.integer(forKey: "stayAwake.displayTimeoutMinutes")
        return m > 0 ? m : 10
    }

    private var actionButtons: some View {
        VStack(spacing: 0) {
            MenuBarButton(label: AppStrings.MenuBar.dashboard,
                          icon: "gauge.with.dots.needle.33percent") { onDashboard() }
            MenuBarButton(label: AppStrings.MenuBar.preferences,
                          icon: "gearshape") { onPreferences() }
            Divider()
                .padding(.vertical, 4)
            MenuBarButton(label: AppStrings.MenuBar.quit,
                          icon: "power",
                          role: .destructive) { onQuit() }
        }
        .padding(.vertical, 4)
    }

    // MARK: - System integration

    /// Bring Activity Monitor forward. macOS doesn't expose a public URL
    /// scheme that selects a specific PID, so we just open the app and
    /// let the user search — still beats hunting through Spotlight.
    fileprivate static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Menu-item-style button

private struct MenuBarButton: View {
    let label: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .modifier(HoverHighlight())
    }
}

// MARK: - Sparkline (#45)

/// Minimal sparkline used in the popover. Deliberately dependency-free
/// (no Charts framework) — the popover has to render in <50ms on a cold
/// menu-bar click, and Charts has first-time-use compile-and-cache cost.
/// Auto-scales y to the sample range; a flat line renders centered.
private struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let (lo, hi) = sampleRange
            Path { path in
                guard samples.count >= 2, w > 0, h > 0 else { return }
                let stepX = w / CGFloat(max(1, samples.count - 1))
                let range = max(0.001, hi - lo)
                for (i, s) in samples.enumerated() {
                    let x = CGFloat(i) * stepX
                    let normalized = (s - lo) / range
                    let y = h - CGFloat(normalized) * h
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else      { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.2)
        }
    }

    private var sampleRange: (Double, Double) {
        guard let lo = samples.min(), let hi = samples.max() else { return (0, 1) }
        if abs(hi - lo) < 0.01 { return (lo - 1, hi + 1) }
        return (lo, hi)
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .onHover { isHovered = $0 }
    }
}
