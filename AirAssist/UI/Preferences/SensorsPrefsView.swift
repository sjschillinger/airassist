import SwiftUI

struct SensorsPrefsView: View {
    let store: ThermalStore
    @State private var searchText = ""

    private var groups: [(category: SensorCategory, sensors: [Sensor])] {
        let filtered = searchText.isEmpty
            ? store.sensors
            : store.sensors.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.rawName.localizedCaseInsensitiveContains(searchText)
              }
        return SensorCategory.allCases.compactMap { cat in
            let group = filtered.filter { $0.category == cat }
            return group.isEmpty ? nil : (cat, group)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            sensorList
            Divider()
            footer
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter sensors", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sensorList: some View {
        List {
            ForEach(groups, id: \.category) { group in
                Section(group.category.rawValue) {
                    ForEach(group.sensors) { sensor in
                        SensorToggleRow(sensor: sensor)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            let total   = store.sensors.count
            let enabled = store.sensors.filter(\.isEnabled).count
            Text("\(enabled) of \(total) sensors shown")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Enable All")  { setAll(true)  }
            Button("Disable All") { setAll(false) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func setAll(_ enabled: Bool) {
        for sensor in store.sensors {
            sensor.isEnabled = enabled
            SensorEnabledPersistence.setEnabled(enabled, sensorID: sensor.id)
        }
    }
}

private struct SensorToggleRow: View {
    let sensor: Sensor

    var body: some View {
        Toggle(isOn: Binding(
            get: { sensor.isEnabled },
            set: {
                sensor.isEnabled = $0
                SensorEnabledPersistence.setEnabled($0, sensorID: sensor.id)
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.displayName).font(.system(size: 13))
                Text(sensor.rawName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
