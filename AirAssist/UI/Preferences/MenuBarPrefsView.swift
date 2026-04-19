import SwiftUI

struct MenuBarPrefsView: View {
    let store: ThermalStore

    @AppStorage("tempUnit")             private var tempUnitRaw: Int    = TempUnit.celsius.rawValue
    @AppStorage("showMenuBarIcon")      private var showIcon: Bool      = true
    @AppStorage("menuBarLayout")        private var layoutRaw: String   = MenuBarLayout.single.rawValue
    @AppStorage("menuBarSlot1Category") private var slot1Cat: String    = SlotCategory.highest.rawValue
    @AppStorage("menuBarSlot1Value")    private var slot1Val: String    = SensorCategory.cpu.rawValue
    @AppStorage("menuBarSlot2Category") private var slot2Cat: String    = SlotCategory.none.rawValue
    @AppStorage("menuBarSlot2Value")    private var slot2Val: String    = ""
    @AppStorage("sensorDisplayMode")    private var displayModeRaw: String = SensorDisplayMode.detailed.rawValue

    private var layout: MenuBarLayout { MenuBarLayout(rawValue: layoutRaw) ?? .single }

    var body: some View {
        Form {
            Section("Temperature") {
                LabeledContent("Unit") {
                    Picker("", selection: Binding(
                        get: { TempUnit(rawValue: tempUnitRaw) ?? .celsius },
                        set: { tempUnitRaw = $0.rawValue }
                    )) {
                        Text("°C").tag(TempUnit.celsius)
                        Text("°F").tag(TempUnit.fahrenheit)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            Section("Menu Bar") {
                LabeledContent("Show icon") {
                    Toggle("", isOn: $showIcon).labelsHidden()
                }

                LabeledContent("Layout") {
                    Picker("", selection: Binding(
                        get: { layout },
                        set: { layoutRaw = $0.rawValue }
                    )) {
                        ForEach(MenuBarLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                LabeledContent("Slot 1") {
                    SlotPicker(category: $slot1Cat, value: $slot1Val, sensors: store.sensors, slotLabel: "Slot 1")
                }

                LabeledContent("Slot 2") {
                    SlotPicker(category: $slot2Cat, value: $slot2Val, sensors: store.sensors, slotLabel: "Slot 2")
                        .disabled(layout == .single)
                        .opacity(layout == .single ? 0.4 : 1)
                }
            }

            Section("Popover") {
                LabeledContent("Sensor list") {
                    Picker("", selection: Binding(
                        get: { SensorDisplayMode(rawValue: displayModeRaw) ?? .detailed },
                        set: { displayModeRaw = $0.rawValue }
                    )) {
                        ForEach(SensorDisplayMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Two-level slot picker

private struct SlotPicker: View {
    @Binding var category: String
    @Binding var value: String
    let sensors: [Sensor]
    var slotLabel: String = "Slot"

    // Sub-options vary by category
    private var subOptions: [(label: String, value: String)] {
        switch category {
        case SlotCategory.highest.rawValue:
            return [("Overall", "overall")]
                + SensorCategory.allCases.map { ($0.rawValue, $0.rawValue) }
        case SlotCategory.average.rawValue:
            return [("All Sensors", "all")]
                + SensorCategory.allCases.map { ($0.rawValue, $0.rawValue) }
        case SlotCategory.individual.rawValue:
            return sensors
                .filter(\.isEnabled)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                .map { ($0.displayName, $0.id) }
        default:
            return []
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Category picker
            Picker("", selection: $category) {
                ForEach(SlotCategory.allCases, id: \.rawValue) { cat in
                    Text(cat.label).tag(cat.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("\(slotLabel) category")
            .onChange(of: category) { _, newCat in
                // Reset to a valid default for the incoming category
                let cat = SlotCategory(rawValue: newCat) ?? .none
                if cat == .individual {
                    value = sensors.filter(\.isEnabled).first?.id ?? ""
                } else {
                    value = cat.defaultValue
                }
            }

            // Sub-option picker (hidden when None)
            if category != SlotCategory.none.rawValue, !subOptions.isEmpty {
                Picker("", selection: $value) {
                    ForEach(subOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .accessibilityLabel("\(slotLabel) value")
            }
        }
    }
}
