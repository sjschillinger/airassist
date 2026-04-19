import SwiftUI
import Darwin

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sensorList
            sparklineRow
            Divider()
            throttleSection
            Divider()
            actionButtons
        }
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
            }
        } label: {
            Image(systemName: store.isPauseActive ? "pause.circle.fill" : "pause.circle")
                .foregroundStyle(store.isPauseActive ? .yellow : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.isPauseActive ? "Throttling paused" : "Pause throttling")
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
                        Text(row.count > 1 ? "\(row.name) (×\(row.count))" : row.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int((row.duty * 100).rounded()))%").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .contentShape(Rectangle())
                    .help(sourcesDescription(row.sources))
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
        if !store.liveThrottledPIDs.isEmpty {
            return "Rules active"
        }
        return "Governor armed"
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
