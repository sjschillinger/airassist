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
    let store: ThermalStore

    @AppStorage("tempUnit")      private var tempUnitRaw: Int    = TempUnit.celsius.rawValue
    @AppStorage("dashSortOrder") private var sortRaw: String     = SensorSortOrder.category.rawValue

    private var unit:      TempUnit         { TempUnit(rawValue: tempUnitRaw) ?? .celsius }
    private var sortOrder: SensorSortOrder  { SensorSortOrder(rawValue: sortRaw) ?? .category }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)]

    private var sortedSensors: [Sensor] {
        let base = store.enabledSensors
        switch sortOrder {
        case .category:
            return base.sorted {
                $0.category.rawValue == $1.category.rawValue
                    ? $0.displayName < $1.displayName
                    : $0.category.rawValue < $1.category.rawValue
            }
        case .nameAsc:   return base.sorted { $0.displayName < $1.displayName }
        case .nameDesc:  return base.sorted { $0.displayName > $1.displayName }
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
            sensorGrid
            if !store.liveThrottledPIDs.isEmpty {
                Divider()
                throttlePanel
            }
        }
        .frame(minWidth: 560, minHeight: 420)
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
                value: "\(Int(store.governor.lastTotalCPUPercent))%",
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
    }

    private var hottestSummaryValue: String {
        guard let h = store.hottestSensor, let v = h.currentValue else { return "—" }
        return "\(h.displayName) \(Int(v))\(unit == .celsius ? "°C" : "°F")"
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
            ForEach(store.liveThrottledPIDs.sorted { $0.duty < $1.duty }, id: \.pid) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("PID \(item.pid)").foregroundStyle(.secondary).monospacedDigit()
                    Text("\(Int((item.duty * 100).rounded()))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Sensor grid

    private var sensorGrid: some View {
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
