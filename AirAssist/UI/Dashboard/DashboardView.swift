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
    @State private var addingPID: pid_t?
    @State private var addingDuty: Double = 0.5

    @AppStorage("tempUnit")       private var tempUnitRaw: Int    = TempUnit.celsius.rawValue
    @AppStorage("dashSortOrder")  private var sortRaw: String     = SensorSortOrder.category.rawValue
    /// Shared with the Governor preferences pane so the "Total CPU" chip
    /// and the CPU-cap slider speak the same language.
    @AppStorage("cpuCapScaleMode") private var cpuScaleRaw: String = "normalized"

    private var unit:      TempUnit         { TempUnit(rawValue: tempUnitRaw) ?? .celsius }
    private var sortOrder: SensorSortOrder  { SensorSortOrder(rawValue: sortRaw) ?? .category }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)]

    private var sortedSensors: [Sensor] {
        let base = store.enabledSensors
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
            summaryBand
            Divider()
            toolbar
            Divider()
            HSplitView {
                sensorGrid
                    .frame(minWidth: 340)
                topCPUPanel
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            }
            if !store.liveThrottledPIDs.isEmpty || !store.governor.reason.isEmpty {
                Divider()
                throttlePanel
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    // MARK: - Top CPU panel (right column)

    private var topCPUPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu").foregroundStyle(.blue)
                Text("Top CPU").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 10)
            Divider()
            if store.governor.lastTopProcesses.isEmpty {
                Text("Sampling processes…")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(topProcesses) { p in
                            topCPURow(p)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.04))
    }

    private var topProcesses: [RunningProcess] {
        let base = store.governor.lastTopProcesses
            .filter { $0.cpuPercent > 0.5 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        return Array(base.prefix(12))
    }

    @ViewBuilder
    private func topCPURow(_ p: RunningProcess) -> some View {
        let existing = store.throttleRules.rule(for: p)
        let throttled = store.liveThrottledPIDs.contains { $0.pid == p.id }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.displayName).font(.subheadline).lineLimit(1)
                    Text(p.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(Int(p.cpuPercent))%")
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(cpuTint(p.cpuPercent))
                if throttled {
                    Image(systemName: "tortoise.fill")
                        .foregroundStyle(.orange).font(.caption)
                        .help("Currently throttled")
                }
                if let rule = existing {
                    Button {
                        store.removeRule(id: rule.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove rule (\(Int(rule.duty * 100))% cap)")
                } else if addingPID == p.id {
                    EmptyView()
                } else {
                    Button {
                        addingPID = p.id
                        addingDuty = 0.5
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add throttle rule for this app")
                }
            }
            if addingPID == p.id {
                HStack {
                    Text("Cap at").font(.caption)
                    Slider(value: $addingDuty, in: 0.05...1.0, step: 0.05)
                    Text("\(Int(addingDuty * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                    Button("Cancel") { addingPID = nil }
                        .controlSize(.small)
                    Button("Save") {
                        store.upsertRule(for: p, duty: addingDuty)
                        addingPID = nil
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(p.displayName), \(Int(p.cpuPercent)) percent CPU\(throttled ? ", throttled" : "")")
    }

    private func cpuTint(_ pct: Double) -> Color {
        switch pct {
        case 80...:  return .red
        case 40...:  return .orange
        default:     return .primary
        }
    }

    // MARK: - Summary band (always visible)

    private var summaryBand: some View {
        HStack(spacing: 10) {
            summaryChip(
                icon: "thermometer.medium",
                label: "Hottest",
                value: hottestSummaryValue,
                tint: hottestSummaryTint
            )
            summaryChip(
                icon: "cpu",
                label: "Total CPU",
                value: formattedTotalCPU,
                tint: .blue
            )
            summaryChip(
                icon: governorChipIcon,
                label: "Governor",
                value: governorChipLabel,
                tint: governorChipTint
            )
            if !store.liveThrottledPIDs.isEmpty {
                summaryChip(
                    icon: "tortoise.fill",
                    label: "Throttling",
                    value: "\(store.liveThrottledPIDs.count)",
                    tint: .orange
                )
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Unit toggle
            Picker("", selection: Binding(
                get: { unit },
                set: { tempUnitRaw = $0.rawValue }
            )) {
                Text("°C").tag(TempUnit.celsius)
                Text("°F").tag(TempUnit.fahrenheit)
            }
            .pickerStyle(.segmented)
            .frame(width: 80)

            Spacer()

            Text("\(store.enabledSensors.count) sensors")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Sort picker
            Picker("Sort", selection: Binding(
                get: { sortOrder },
                set: { sortRaw = $0.rawValue }
            )) {
                ForEach(SensorSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .frame(width: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            sensorGridEmpty
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(sortedSensors) { sensor in
                        SensorCardView(sensor: sensor,
                                       thresholds: store.thresholds,
                                       unit: unit)
                    }
                }
                .padding(16)
            }
        }
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
