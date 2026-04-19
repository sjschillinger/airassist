import SwiftUI

struct PreferencesView: View {
    let store: ThermalStore

    // Track the selected tab so ⌘1–⌘4 can switch it. Native macOS prefs
    // windows always bind these; without them, keyboard users are stuck
    // tabbing through a grid or mousing.
    @State private var selection: Int = 0

    var body: some View {
        TabView(selection: $selection) {
            GeneralPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.general,    systemImage: "gearshape") }
                .tag(0)
            MenuBarPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.menuBar,    systemImage: "menubar.rectangle") }
                .tag(1)
            SensorsPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.sensors,    systemImage: "thermometer.medium") }
                .tag(2)
            ThrottlingPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.throttling, systemImage: "gauge.with.dots.needle.67percent") }
                .tag(3)
        }
        .frame(minWidth: 560, minHeight: 520)
        // Zero-sized invisible buttons carry the shortcuts. SwiftUI TabView
        // on macOS doesn't accept `.keyboardShortcut` directly on .tabItem,
        // so this is the canonical workaround.
        .background(
            ZStack {
                Button("") { selection = 0 }.keyboardShortcut("1", modifiers: .command)
                Button("") { selection = 1 }.keyboardShortcut("2", modifiers: .command)
                Button("") { selection = 2 }.keyboardShortcut("3", modifiers: .command)
                Button("") { selection = 3 }.keyboardShortcut("4", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }
}
