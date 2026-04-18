import SwiftUI

struct PreferencesView: View {
    let store: ThermalStore

    var body: some View {
        TabView {
            GeneralPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.general,    systemImage: "gearshape") }
            DisplayPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.display,    systemImage: "menubar.rectangle") }
            ThresholdsPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.thresholds, systemImage: "thermometer.medium") }
            SensorsPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.sensors,    systemImage: "sensor") }
            CPURulesPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.cpuRules,   systemImage: "cpu") }
            GovernorPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.governor,   systemImage: "gauge.with.dots.needle.67percent") }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}
