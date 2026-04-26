import SwiftUI

/// Combined Sensors + Thresholds tab.
/// Top: per-category warm/hot threshold editors (collapsible).
/// Bottom: sensor enable/disable list with search.
struct SensorsPrefsView: View {
    let store: ThermalStore
    @State private var searchText = ""
    @State private var thresholdsExpanded = true

    private var groups: [(category: SensorCategory, sensors: [Sensor])] {
        let filtered = searchText.isEmpty
            ? store.sensors
            : store.sensors.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.rawName.localizedCaseInsensitiveContains(searchText)
              }
        return SensorCategory.allCases.compactMap { cat in
            let group = filtered
                .filter { $0.category == cat }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            return group.isEmpty ? nil : (cat, group)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            thresholdsSection
            Divider()
            searchBar
            Divider()
            sensorList
            Divider()
            footer
        }
    }

    // MARK: - Thresholds

    private var thresholdsSection: some View {
        DisclosureGroup(isExpanded: $thresholdsExpanded) {
            VStack(spacing: 6) {
                thresholdsHeader
                thresholdRow("CPU",     warm: \.cpu.warm,     hot: \.cpu.hot)
                thresholdRow("GPU",     warm: \.gpu.warm,     hot: \.gpu.hot)
                thresholdRow("SoC",     warm: \.soc.warm,     hot: \.soc.hot)
                thresholdRow("Battery", warm: \.battery.warm, hot: \.battery.hot)
                thresholdRow("Storage", warm: \.storage.warm, hot: \.storage.hot)
                thresholdRow("Other",   warm: \.other.warm,   hot: \.other.hot)
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        store.thresholds = ThresholdSettings()
                        ThresholdPersistence.save(store.thresholds)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } label: {
            HStack {
                Image(systemName: "thermometer.medium")
                Text("Temperature thresholds").font(.headline)
                InfoButton(text: "Set the warm/hot color bands per sensor category. These drive the menu bar tint, the popover color stripes, and the dashboard. They do NOT throttle anything — the governor uses its own ceiling in Throttling preferences. Different categories run at different normal temps (battery is much cooler than CPU), which is why each gets its own pair.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var thresholdsHeader: some View {
        HStack {
            Text("Category").frame(maxWidth: .infinity, alignment: .leading)
            Text("Warm").frame(width: 72, alignment: .trailing)
            Text("Hot").frame(width: 72, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func thresholdRow(
        _ label: String,
        warm warmPath: WritableKeyPath<ThresholdSettings, Double>,
        hot  hotPath:  WritableKeyPath<ThresholdSettings, Double>
    ) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            thresholdField(path: warmPath, tint: .orange, a11y: "\(label) warm threshold in degrees")
            thresholdField(path: hotPath,  tint: .red,    a11y: "\(label) hot threshold in degrees")
        }
    }

    private func thresholdField(
        path: WritableKeyPath<ThresholdSettings, Double>,
        tint: Color,
        a11y: String
    ) -> some View {
        let binding = Binding<Double>(
            get: { store.thresholds[keyPath: path] },
            set: {
                store.thresholds[keyPath: path] = $0
                ThresholdPersistence.save(store.thresholds)
            }
        )
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            TextField("", value: binding, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(a11y)
        }
        .frame(width: 72)
    }

    // MARK: - Sensor list

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter sensors", text: $searchText)
                .textFieldStyle(.plain)
            InfoButton(text: "Disable sensors you don't care about to declutter the dashboard and menu bar. Disabled sensors are excluded from \"Highest\" calculations too — useful if a particular sensor is consistently the hottest but isn't representative (e.g. a thermal pad reading you don't trust).")
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
