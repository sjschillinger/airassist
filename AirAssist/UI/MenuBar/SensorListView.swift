import SwiftUI

// MARK: - Compact per-category summary (High / Avg / Low)

/// Drop-in replacement for `SensorListView` when the user picks
/// "Summary" in Menu Bar prefs. Shows one row per category with the
/// hottest, average, and coolest current reading across that category's
/// enabled sensors. Much shorter on Macs with many dies (M-Pro/Max).
struct SensorSummaryView: View {
    let groups: [(category: SensorCategory, sensors: [Sensor])]
    let thresholds: ThresholdSettings
    let unit: TempUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column legend
            HStack(spacing: 0) {
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                columnLabel("High")
                columnLabel("Avg")
                columnLabel("Low")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)

            Divider()

            ForEach(groups, id: \.category) { group in
                row(for: group.category, sensors: group.sensors)
            }
        }
    }

    private func columnLabel(_ s: String) -> some View {
        Text(s)
            .frame(width: 46, alignment: .trailing)
    }

    @ViewBuilder
    private func row(for category: SensorCategory, sensors: [Sensor]) -> some View {
        let values = sensors.compactMap(\.currentValue)
        HStack(spacing: 0) {
            Text(category.rawValue)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            if values.isEmpty {
                dash; dash; dash
            } else {
                let ct = thresholds.thresholds(for: category)
                let high = values.max() ?? 0
                let low  = values.min() ?? 0
                let avg  = values.reduce(0, +) / Double(values.count)
                value(high, state: stateFor(high, thresholds: ct))
                value(avg,  state: stateFor(avg,  thresholds: ct))
                value(low,  state: stateFor(low,  thresholds: ct))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var dash: some View {
        Text("–")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 46, alignment: .trailing)
    }

    private func value(_ v: Double, state: ThresholdState) -> some View {
        Text(unit.format(v))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(color(for: state))
            .frame(width: 46, alignment: .trailing)
    }

    private func stateFor(_ v: Double, thresholds ct: CategoryThresholds) -> ThresholdState {
        if v >= ct.hot  { return .hot }
        if v >= ct.warm { return .warm }
        return .cool
    }

    private func color(for state: ThresholdState) -> Color {
        switch state {
        case .cool:    return .green
        case .warm:    return .orange
        case .hot:     return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - Full grouped list used in the popover

/// Threshold at which a category auto-collapses on first sight. Pro/Max
/// Macs commonly have 10+ "CPU Die N" sensors — keeping all of them open by
/// default produces a wall of near-identical rows. Categories at or below
/// this count always default to expanded.
private let autoCollapseThreshold = 5

struct SensorListView: View {
    let groups: [(category: SensorCategory, sensors: [Sensor])]
    let thresholds: ThresholdSettings
    let unit: TempUnit

    /// Categories the user has manually collapsed. Keyed by
    /// `SensorCategory.rawValue`. Persisted as CSV to stay forward-
    /// compatible if the enum grows.
    @AppStorage("sensorList.collapsedCategories")
    private var collapsedCategoriesCSV: String = ""

    /// Categories the user has manually *expanded* (overriding auto-
    /// collapse). Separate key so a user who opens CPU once stays with it
    /// expanded across launches without us losing the auto-collapse for
    /// future fresh installs.
    @AppStorage("sensorList.expandedCategories")
    private var expandedCategoriesCSV: String = ""

    private var manuallyCollapsed: Set<String> {
        Set(collapsedCategoriesCSV.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
    private var manuallyExpanded: Set<String> {
        Set(expandedCategoriesCSV.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private func isCollapsed(_ category: SensorCategory, count: Int) -> Bool {
        let key = category.rawValue
        if manuallyCollapsed.contains(key) { return true }
        if manuallyExpanded.contains(key)  { return false }
        // No explicit user choice: auto-collapse only when the category is
        // noisy.
        return count > autoCollapseThreshold
    }

    private func toggle(_ category: SensorCategory, currentlyCollapsed: Bool) {
        let key = category.rawValue
        var collapsed = manuallyCollapsed
        var expanded  = manuallyExpanded
        if currentlyCollapsed {
            collapsed.remove(key)
            expanded.insert(key)
        } else {
            expanded.remove(key)
            collapsed.insert(key)
        }
        collapsedCategoriesCSV = collapsed.sorted().joined(separator: ",")
        expandedCategoriesCSV  = expanded.sorted().joined(separator: ",")
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(groups, id: \.category) { group in
                    let collapsed = isCollapsed(group.category, count: group.sensors.count)
                    Section {
                        if !collapsed {
                            ForEach(group.sensors) { sensor in
                                SensorRowView(sensor: sensor,
                                              thresholds: thresholds,
                                              unit: unit)
                            }
                        }
                    } header: {
                        CategoryHeaderView(
                            category: group.category,
                            sensors: group.sensors,
                            thresholds: thresholds,
                            unit: unit,
                            isCollapsed: collapsed,
                            isCollapsible: group.sensors.count > 1,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    toggle(group.category, currentlyCollapsed: collapsed)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Category header

private struct CategoryHeaderView: View {
    let category: SensorCategory
    let sensors: [Sensor]
    let thresholds: ThresholdSettings
    let unit: TempUnit
    let isCollapsed: Bool
    let isCollapsible: Bool
    let onToggle: () -> Void

    /// Hottest current value in this category (used as the collapsed-row
    /// summary). Nil if no readings yet.
    private var hottest: Double? {
        sensors.compactMap(\.currentValue).max()
    }

    private var hottestState: ThresholdState {
        guard let v = hottest else { return .unknown }
        let t = thresholds.thresholds(for: category)
        if v >= t.hot  { return .hot }
        if v >= t.warm { return .warm }
        return .cool
    }

    private var stateColor: Color {
        switch hottestState {
        case .cool:    return .green
        case .warm:    return .orange
        case .hot:     return .red
        case .unknown: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if isCollapsible {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10, alignment: .center)
            } else {
                // Preserve alignment with collapsible headers.
                Spacer().frame(width: 10)
            }

            Text(category.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            if isCollapsed {
                Text("· \(sensors.count)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isCollapsed, let v = hottest {
                Text(unit.format(v))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(stateColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsible { onToggle() }
        }
        .help(isCollapsible
              ? (isCollapsed ? "Show all \(category.rawValue) sensors"
                             : "Collapse \(category.rawValue) sensors")
              : "")
    }
}

// MARK: - Individual sensor row

struct SensorRowView: View {
    let sensor: Sensor
    let thresholds: ThresholdSettings
    let unit: TempUnit

    private var state: ThresholdState {
        sensor.thresholdState(using: thresholds)
    }

    private var stateColor: Color {
        switch state {
        case .cool:    return .green
        case .warm:    return .orange
        case .hot:     return .red
        case .unknown: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)

            Text(sensor.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let value = sensor.currentValue {
                Text(unit.format(value))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(stateColor)
            } else {
                Text("–")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}
