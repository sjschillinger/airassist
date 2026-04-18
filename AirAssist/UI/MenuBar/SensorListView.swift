import SwiftUI

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
