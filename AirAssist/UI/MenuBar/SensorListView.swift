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

struct SensorListView: View {
    let groups: [(category: SensorCategory, sensors: [Sensor])]
    let thresholds: ThresholdSettings
    let unit: TempUnit

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.sensors) { sensor in
                            SensorRowView(sensor: sensor,
                                          thresholds: thresholds,
                                          unit: unit)
                        }
                    } header: {
                        CategoryHeaderView(category: group.category)
                    }
                }
            }
        }
    }
}

// MARK: - Category header

private struct CategoryHeaderView: View {
    let category: SensorCategory

    var body: some View {
        Text(category.rawValue.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
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
