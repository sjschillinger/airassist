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
            toolbar
            Divider()
            sensorGrid
        }
        .frame(minWidth: 520, minHeight: 380)
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
