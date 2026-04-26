import SwiftUI

struct MenuBarPrefsView: View {
    let store: ThermalStore

    @AppStorage("tempUnit")             private var tempUnitRaw: Int    = TempUnit.celsius.rawValue
    @AppStorage("showMenuBarIcon")      private var showIcon: Bool      = true
    @AppStorage("showMenuBarSourceBadge") private var showSourceBadge: Bool = true
    @AppStorage("showMenuBarTrendGlyph")  private var showTrendGlyph: Bool  = true
    @AppStorage("showMenuBarHeadroomStrip") private var showHeadroomStrip: Bool = true
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
                PrefRow("Unit") {
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
                PrefRow("Show icon",
                        info: "Show the Air Assist thermometer glyph alongside the temperature in the menu bar. Turn off if you only want the numbers.") {
                    Toggle("", isOn: $showIcon).labelsHidden()
                }

                PrefRow("Layout",
                        info: """
                        Single — one slot with the icon and a single value.
                        Side by Side — two slots laid out horizontally (e.g. CPU and GPU at a glance).
                        Stacked — two compact values stacked vertically; text-only.
                        """) {
                    Picker("", selection: Binding(
                        get: { layout },
                        set: { layoutRaw = $0.rawValue }
                    )) {
                        ForEach(MenuBarLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                PrefRow("Slot 1",
                        info: """
                        What the first slot displays.
                        Highest — the hottest sensor (overall, or within a category).
                        Average — the average across sensors (overall or by category).
                        Individual — pick one specific sensor.
                        None — hide the slot.
                        """) {
                    SlotPicker(category: $slot1Cat, value: $slot1Val, sensors: store.sensors, slotLabel: "Slot 1")
                }

                PrefRow("Slot 2",
                        info: "What the second slot displays. Only used when Layout is Side by Side or Stacked.") {
                    SlotPicker(category: $slot2Cat, value: $slot2Val, sensors: store.sensors, slotLabel: "Slot 2")
                        .disabled(layout == .single)
                        .opacity(layout == .single ? 0.4 : 1)
                }

                // The remaining three are visual augments to slots already
                // configured above — they only have an effect when their
                // pre-conditions are met (e.g. badge needs a Highest slot).
                // The help text spells out those preconditions so the user
                // doesn't toggle them and wonder why nothing changed.
                PrefRow("Source badge",
                        info: "Prefix the value with a one-letter category badge (C CPU, G GPU, S SoC, B battery, D disk) when a Highest slot is showing. Tells you at a glance which sensor won the “hottest” race so 91° isn’t ambiguous.") {
                    Toggle("", isOn: $showSourceBadge).labelsHidden()
                }

                PrefRow("Trend arrow",
                        info: "Show a small ↑ or ↓ next to a slot when its recent history shows a clear rise or fall. Hidden when steady — the menu bar doesn’t flicker on sensor jitter.") {
                    Toggle("", isOn: $showTrendGlyph).labelsHidden()
                }

                PrefRow("Headroom strip",
                        info: "Thin bar across the bottom of the menu bar item. Fills left-to-right and ramps blue → orange → red as the hottest visible sensor approaches its hot threshold. Gives you advance warning before the icon turns orange. Hidden when the Mac is cool.") {
                    Toggle("", isOn: $showHeadroomStrip).labelsHidden()
                }
            }

            Section("Popover") {
                PrefRow("Sensor list",
                        info: "Summary — compact list, one line per sensor.\nDetailed — adds per-sensor source, threshold, and history glyph.") {
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
