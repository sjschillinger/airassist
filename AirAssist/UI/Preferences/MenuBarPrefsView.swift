import SwiftUI

struct MenuBarPrefsView: View {
    let store: ThermalStore

    @AppStorage("tempUnit")             private var tempUnitRaw: Int    = TempUnit.celsius.rawValue
    @AppStorage("showMenuBarIcon")      private var showIcon: Bool      = true
    @AppStorage("showMenuBarSourceBadge") private var showSourceBadge: Bool = true
    @AppStorage("showMenuBarTrendGlyph")  private var showTrendGlyph: Bool  = true
    @AppStorage("showMenuBarHeadroomStrip") private var showHeadroomStrip: Bool = true
    @AppStorage("menuBarLayout")        private var layoutRaw: String   = MenuBarLayout.single.rawValue
    @AppStorage("menuBarSlot1Metric")   private var slot1Metric: String = SlotMetric.temperature.rawValue
    @AppStorage("menuBarSlot1Category") private var slot1Cat: String    = SlotCategory.highest.rawValue
    @AppStorage("menuBarSlot1Value")    private var slot1Val: String    = SensorCategory.cpu.rawValue
    @AppStorage("menuBarSlot2Metric")   private var slot2Metric: String = SlotMetric.none.rawValue
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
                        What the first slot displays. Pick a metric:
                        Temperature — Highest / Average / Individual sensor (sub-config).
                        CPU usage — total system CPU as a percent.
                        None — hide the slot.
                        """) {
                    SlotPicker(metric: $slot1Metric,
                               category: $slot1Cat,
                               value: $slot1Val,
                               sensors: store.sensors,
                               slotLabel: "Slot 1")
                }

                PrefRow("Slot 2",
                        info: "What the second slot displays. Pair complementary metrics (e.g. Temperature + CPU usage) so the two slots tell different parts of the story. Only used when Layout is Side by Side or Stacked.") {
                    SlotPicker(metric: $slot2Metric,
                               category: $slot2Cat,
                               value: $slot2Val,
                               sensors: store.sensors,
                               slotLabel: "Slot 2")
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

            Section("Show in popover") {
                // Per-section visibility toggles. Defaults to all on,
                // matching the popover's pre-Phase-5 behavior. Hiding
                // a section just collapses that part of the popover —
                // the underlying logic (governor, sensors, etc.) keeps
                // running.
                ForEach(PopoverSection.allCases) { section in
                    PopoverSectionToggleRow(section: section)
                }
                Text("Header (Air Assist + pause menu) and the Dashboard / Preferences / Quit actions are always visible — they're how you reach this pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Slot picker (Metric → Sub-config, v0.14)
//
// Two tiers:
//   1. Metric — Temperature / CPU usage / None (top-level)
//   2. Sub-config — only relevant for Temperature: existing
//      Highest/Average/Individual + scope.

private struct SlotPicker: View {
    @Binding var metric: String
    @Binding var category: String
    @Binding var value: String
    let sensors: [Sensor]
    var slotLabel: String = "Slot"

    private var metricEnum: SlotMetric {
        SlotMetric(rawValue: metric) ?? .none
    }

    // Sub-options vary by category. Only consulted when metric == .temperature.
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
            // Top-level metric picker.
            Picker("", selection: $metric) {
                ForEach(SlotMetric.allCases, id: \.rawValue) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("\(slotLabel) metric")

            if metricEnum == .temperature {
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

                if category != SlotCategory.none.rawValue, !subOptions.isEmpty {
                    Picker("", selection: $value) {
                        ForEach(subOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .accessibilityLabel("\(slotLabel) value")
                }
            }
            // Other metrics (.cpuTotal, .none) are fully specified by
            // the metric alone — no sub-config.
        }
    }
}

// MARK: - Popover section toggle row (v0.14)

/// One row per `PopoverSection` in the "Show in popover" preferences
/// section. Reads/writes through `PopoverSectionPrefs` directly rather
/// than `@AppStorage` because the helper is the source of truth for
/// the storage shape (JSON-encoded list of hidden raw values), and
/// we want both reads and writes to go through the same helper so
/// the in-memory and on-disk views stay consistent.
///
/// The view uses a `@State` mirror that's seeded on appear and
/// updated on user toggles. SwiftUI's `@AppStorage` doesn't compose
/// neatly with the `Set<PopoverSection>`-shaped storage we have, and
/// hand-rolling the binding keeps the helper's API surface honest.
private struct PopoverSectionToggleRow: View {
    let section: PopoverSection

    @State private var isVisible: Bool = true

    var body: some View {
        PrefRow(section.label, info: section.helpDescription) {
            Toggle("", isOn: Binding(
                get: { isVisible },
                set: { newValue in
                    isVisible = newValue
                    PopoverSectionPrefs.setVisible(section, newValue)
                }
            ))
            .labelsHidden()
            .accessibilityLabel("Show \(section.label) in popover")
        }
        .onAppear {
            // Seed from persisted state on every appear so the
            // toggles reflect any out-of-band changes (Restore
            // Defaults action, future drag-to-reorder UI, etc.).
            isVisible = PopoverSectionPrefs.isVisible(section)
        }
    }
}
