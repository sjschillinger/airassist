import SwiftUI

enum SensorSortOrder: String, CaseIterable, Identifiable {
    case category  = "Category"
    case nameAsc   = "Name A→Z"
    case nameDesc  = "Name Z→A"
    case tempDesc  = "Temp ↓"
    case tempAsc   = "Temp ↑"
    var id: String { rawValue }
}

struct DashboardView: View {
    @Bindable var store: ThermalStore
    /// Which category group cards are expanded to show their individual
    /// sensors. Collapsed by default so a Mac with dozens of dies shows a
    /// handful of summary cards instead of one enormous scroll.
    @State private var expandedCategories: Set<SensorCategory> = []

    @AppStorage("tempUnit")       private var tempUnitRaw: Int    = TempUnit.celsius.rawValue
    @AppStorage("dashSortOrder")  private var sortRaw: String     = SensorSortOrder.category.rawValue
    /// Shared with the Governor preferences pane so the "Total CPU" chip
    /// and the CPU-cap slider speak the same language.
    @AppStorage("cpuCapScaleMode") private var cpuScaleRaw: String = "normalized"

    private var unit:      TempUnit         { TempUnit(rawValue: tempUnitRaw) ?? .celsius }
    private var sortOrder: SensorSortOrder  { SensorSortOrder(rawValue: sortRaw) ?? .category }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)]

    private var sortedSensors: [Sensor] {
        // Pinned (favorited) sensors always sort to the top, regardless of
        // the picked sort order. Within each partition the chosen order
        // applies normally.
        let favs = SensorFavorites.ids()
        let pinned    = store.enabledSensors.filter {  favs.contains($0.id) }
        let unpinned  = store.enabledSensors.filter { !favs.contains($0.id) }
        return sortPartition(pinned) + sortPartition(unpinned)
    }

    private func sortPartition(_ base: [Sensor]) -> [Sensor] {
        switch sortOrder {
        case .category:
            return base.sorted {
                $0.category.rawValue == $1.category.rawValue
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : $0.category.rawValue < $1.category.rawValue
            }
        case .nameAsc:
            return base.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .nameDesc:
            return base.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending }
        case .tempDesc:  return base.sorted { ($0.currentValue ?? -1) > ($1.currentValue ?? -1) }
        case .tempAsc:   return base.sorted { ($0.currentValue ?? 999) < ($1.currentValue ?? 999) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header stays pinned; everything else lives in ONE scroll so
            // the sensor grid flows at its natural height and the panels
            // below it are always reachable. (Previously a fill-height
            // HSplitView with no outer scroll squished the grid to a
            // sliver and hid the lower panels off-screen.)
            dashboardHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sensorGrid
                    Divider()
                    topCPUSection
                    if !store.liveThrottledPIDs.isEmpty || !store.governor.reason.isEmpty {
                        Divider()
                        throttlePanel
                    }
                    if !store.throttleActivityLog.entries.isEmpty {
                        Divider()
                        recentActivityPanel
                    }
                    Divider()
                    WeeklySummaryView(store: store)
                    Divider()
                    CPUConsumersView(store: store)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    // MARK: - Header (status chips + sensor controls, one row)

    /// Single top row: live status chips on the left, the sensor-list
    /// controls (unit + sort) on the right. Replaces the old stacked
    /// summary-band + toolbar, which read as two disconnected strips.
    private var dashboardHeader: some View {
        HStack(spacing: 10) {
            summaryChip(icon: "thermometer.medium", label: "Hottest",
                        value: hottestSummaryValue, tint: hottestSummaryTint)
            summaryChip(icon: "cpu", label: "Total CPU",
                        value: formattedTotalCPU, tint: .blue)
            summaryChip(icon: governorChipIcon, label: "Governor",
                        value: governorChipLabel, tint: governorChipTint)
            if !store.liveThrottledPIDs.isEmpty {
                summaryChip(icon: "tortoise.fill", label: "Throttling",
                            value: "\(store.liveThrottledPIDs.count)", tint: .orange)
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { unit },
                set: { tempUnitRaw = $0.rawValue }
            )) {
                Text("°C").tag(TempUnit.celsius)
                Text("°F").tag(TempUnit.fahrenheit)
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            .labelsHidden()
            .accessibilityLabel("Temperature unit")

            Picker("", selection: Binding(
                get: { sortOrder },
                set: { sortRaw = $0.rawValue }
            )) {
                ForEach(SensorSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .labelsHidden()
            .accessibilityLabel("Sort sensors by")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Recent activity panel

    private var recentActivityPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Recent throttle activity").font(.headline)
                Spacer()
                Text("\(store.throttleActivityLog.entries.count) events")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear") { store.throttleActivityLog.clear() }
                    .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.throttleActivityLog.entries.prefix(20)) { entry in
                        activityRow(entry: entry)
                        Divider().padding(.vertical, 4)
                    }
                }
            }
            .frame(height: 56)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func activityRow(entry: ThrottleActivityLog.Entry) -> some View {
        let icon: String = entry.kind == .apply ? "pause.circle.fill" : "play.circle.fill"
        let tint: Color = {
            switch entry.source {
            case .governor: return .red
            case .rule:     return .orange
            case .manual:   return .purple
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.caption).lineLimit(1)
                HStack(spacing: 4) {
                    Text(sourceLabel(entry.source))
                        .font(.caption2).foregroundStyle(.secondary)
                    if entry.kind == .apply {
                        Text("· \(Int((entry.duty * 100).rounded()))%")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(entry.timestamp, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 150, alignment: .leading)
    }

    private func sourceLabel(_ s: ThrottleSource) -> String {
        switch s {
        case .governor: return "Governor"
        case .rule:     return "Rule"
        case .manual:   return "Manual"
        }
    }

    // MARK: - Top CPU section (full-width, inline in the scroll)

    /// Read-only "what's hot right now" — a compact glance, capped at a few
    /// rows. The full interactive list (with limit controls) lives in the
    /// Activity window, reachable via the header button. Inline rows only
    /// (no inner ScrollView): the whole dashboard is one scroll now.
    private var topCPUSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu").foregroundStyle(.blue)
                Text("Top CPU").font(.headline)
                Spacer()
                Button {
                    ActivityWindowController.shared(store: store).show()
                } label: {
                    Label("Open Activity", systemImage: "arrow.up.forward.app")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Open the Activity window to monitor apps and set per-app CPU limits")
            }
            if store.governor.lastTopProcesses.isEmpty {
                Text("Sampling processes…")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(topProcesses) { p in
                        topCPURow(p)
                        if p.id != topProcesses.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var topProcesses: [RunningProcess] {
        let base = store.governor.lastTopProcesses
            .filter { $0.cpuPercent > 0.5 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        return Array(base.prefix(6))
    }

    /// Read-only "what's hot right now" row. Setting limits moved to the
    /// dedicated Activity window (the "Open Activity" button in this
    /// panel's header) so the Dashboard stays monitoring-only and there's
    /// one home for throttle controls.
    @ViewBuilder
    private func topCPURow(_ p: RunningProcess) -> some View {
        let existing = store.throttleRules.rule(for: p)
        let throttled = store.liveThrottledPIDs.contains { $0.pid == p.id }

        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(p.displayName).font(.subheadline).lineLimit(1)
                Text(p.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let rule = existing {
                Text("limit \(Int(rule.duty * 100))%")
                    .font(.caption2).foregroundStyle(.purple)
                    .help("This app has a \(Int(rule.duty * 100))% CPU limit")
            }
            Text("\(Int(p.cpuPercent))%")
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(CPUTint.color(p.cpuPercent))
            if throttled {
                Image(systemName: "tortoise.fill")
                    .foregroundStyle(.orange).font(.caption)
                    .help("Currently throttled")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(p.displayName), \(Int(p.cpuPercent)) percent CPU\(throttled ? ", currently throttled" : "")")
    }

    // CPU% color tier — see `CPUTint` for the palette + rationale.
    // Note: pre-v0.14 this view used a different palette (40/80
    // thresholds, no .secondary tier). Switched to the unified
    // 4-tier palette so the same CPU% is the same color across
    // popover / throttling prefs / dashboard.

    // MARK: - Summary chip

    private func summaryChip(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.subheadline).bold().monospacedDigit()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var hottestSummaryValue: String {
        guard let h = store.hottestSensor, let v = h.currentValue else { return "—" }
        return "\(h.displayName) \(Int(v))\(unit == .celsius ? "°C" : "°F")"
    }
    /// "Total CPU" value formatted per the shared CPU scale preference.
    /// Normalized mode divides by the number of online cores so the number
    /// maxes at 100%; per-core mode preserves the kernel's sum (matches
    /// `top` / Activity Monitor).
    private var formattedTotalCPU: String {
        let raw = store.governor.lastTotalCPUPercent
        if cpuScaleRaw == "perCore" {
            return "\(Int(raw.rounded()))%"
        }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let v = raw / cores
        if v < 10 { return String(format: "%.1f%%", v) }
        return "\(Int(v.rounded()))%"
    }

    private var hottestSummaryTint: Color {
        guard let h = store.hottestSensor else { return .secondary }
        switch h.thresholdState(using: store.thresholds) {
        case .hot:  return .red
        case .warm: return .orange
        case .cool: return .green
        case .unknown: return .secondary
        }
    }

    private var governorChipLabel: String {
        if store.isPauseActive                        { return "Paused" }
        if store.governorConfig.isOff                 { return "Off" }
        if store.governor.isTempThrottling || store.governor.isCPUThrottling { return "Active" }
        return "Armed"
    }
    private var governorChipTint: Color {
        if store.isPauseActive                        { return .yellow }
        if store.governorConfig.isOff                 { return .secondary }
        if store.governor.isTempThrottling || store.governor.isCPUThrottling { return .orange }
        return .green
    }
    private var governorChipIcon: String {
        if store.isPauseActive { return "pause.circle.fill" }
        return "gauge.with.dots.needle.67percent"
    }


    // MARK: - Throttle panel

    private var throttlePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "tortoise.fill").foregroundStyle(.orange)
                Text("Currently throttling \(store.liveThrottledPIDs.count) process\(store.liveThrottledPIDs.count == 1 ? "" : "es")")
                    .font(.subheadline).bold()
                Spacer()
                if store.governor.isTempThrottling {
                    Label("Temp", systemImage: "thermometer.high")
                        .labelStyle(.titleAndIcon).font(.caption)
                        .foregroundStyle(.red)
                }
                if store.governor.isCPUThrottling {
                    Label("CPU", systemImage: "cpu")
                        .labelStyle(.titleAndIcon).font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if !store.governor.reason.isEmpty {
                Text(store.governor.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.liveThrottledPIDs.sorted { $0.duty < $1.duty }, id: \.pid) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("PID \(item.pid)").foregroundStyle(.secondary).monospacedDigit()
                    Text("\(Int((item.duty * 100).rounded()))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.name), PID \(item.pid), capped at \(Int((item.duty * 100).rounded())) percent")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Sensor grid

    @ViewBuilder
    private var sensorGrid: some View {
        if sortedSensors.isEmpty {
            // Keep a usable height for the empty/booting state inside the
            // outer scroll, since it no longer fills the window.
            sensorGridEmpty
                .frame(minHeight: 220)
        } else {
            // One collapsible card per category instead of a flat grid of
            // every die — keeps the scroll short on Macs with many sensors.
            VStack(spacing: 10) {
                ForEach(store.sensorsByCategory, id: \.category) { group in
                    groupCard(group.category, group.sensors)
                }
            }
            .padding(16)
        }
    }

    /// Large, tappable summary card for one sensor category. Collapsed it
    /// shows the group's hottest reading + count; expanded it reveals the
    /// individual sensor cards in a sub-grid.
    @ViewBuilder
    private func groupCard(_ category: SensorCategory, _ sensors: [Sensor]) -> some View {
        let isExpanded = expandedCategories.contains(category)
        let values = sensors.compactMap(\.currentValue)
        let high = values.max()
        let avg  = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let tint = categoryTint(sensors)

        VStack(spacing: 0) {
            Button {
                if isExpanded { expandedCategories.remove(category) }
                else          { expandedCategories.insert(category) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: categoryIcon(category))
                        .font(.title2).foregroundStyle(tint).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.rawValue).font(.headline)
                        Text("\(sensors.count) sensor\(sensors.count == 1 ? "" : "s")"
                             + (avg.map { " · avg \(formatTemp($0))" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let high {
                        Text(formatTemp(high))
                            .font(.system(.title3, design: .rounded).monospacedDigit())
                            .foregroundStyle(tint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category.rawValue), \(sensors.count) sensors"
                + (high.map { ", hottest \(formatTemp($0))" } ?? "")
                + (isExpanded ? ", expanded" : ", collapsed"))

            if isExpanded {
                Divider()
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(sortPartition(sensors)) { sensor in
                        SensorCardView(sensor: sensor,
                                       thresholds: store.thresholds,
                                       unit: unit)
                    }
                }
                .padding(12)
            }
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    /// Tint a group by the worst (hottest) threshold state across its
    /// sensors — red if anything's hot, then orange, then green.
    private func categoryTint(_ sensors: [Sensor]) -> Color {
        let states = sensors.map { $0.thresholdState(using: store.thresholds) }
        if states.contains(where: { $0 == .hot })  { return .red }
        if states.contains(where: { $0 == .warm }) { return .orange }
        if states.contains(where: { $0 == .cool }) { return .green }
        return .secondary
    }

    private func categoryIcon(_ category: SensorCategory) -> String {
        switch category {
        case .cpu:     return "cpu"
        case .gpu:     return "cpu.fill"
        case .soc:     return "memorychip"
        case .battery: return "battery.100"
        case .storage: return "internaldrive"
        case .other:   return "thermometer.medium"
        }
    }

    /// Format a Celsius reading in the user's chosen unit.
    private func formatTemp(_ celsius: Double) -> String {
        let v = unit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(v.rounded()))°\(unit == .celsius ? "C" : "F")"
    }

    /// Shown when the grid has nothing to render — either the sensor
    /// service hasn't produced anything yet (booting), it's been long
    /// enough that we're confident something's wrong (unavailable),
    /// or the user has disabled every sensor in Preferences.
    @ViewBuilder
    private var sensorGridEmpty: some View {
        let allDisabled = !store.sensors.isEmpty && store.enabledSensors.isEmpty
        VStack(spacing: 12) {
            Spacer()
            if allDisabled {
                Image(systemName: "eye.slash")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("All sensors hidden")
                    .font(.headline)
                Text("Re-enable sensors in Preferences → Sensors to see them here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            } else {
                switch store.sensorService.readState {
                case .booting:
                    ProgressView().controlSize(.large)
                    Text("Reading sensors…")
                        .font(.headline).foregroundStyle(.secondary)
                case .unavailable:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36)).foregroundStyle(.orange)
                    Text("Sensors unavailable")
                        .font(.headline)
                    Text("macOS returned no thermal sensors. Quit and re-launch Air Assist. If this persists on a signed release build, file a bug with your Mac model (`sysctl hw.model`) and macOS version.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                case .ok:
                    EmptyView()   // unreachable when sortedSensors is empty
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
