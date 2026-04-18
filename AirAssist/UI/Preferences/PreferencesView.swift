import SwiftUI

struct PreferencesView: View {
    let store: ThermalStore

    var body: some View {
        TabView {
            GeneralPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.general,    systemImage: "gearshape") }
            DisplayPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.menuBar,    systemImage: "menubar.rectangle") }
            SensorsPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.sensors,    systemImage: "thermometer.medium") }
            ThrottlingPrefsView(store: store)
                .tabItem { Label(AppStrings.Preferences.throttling, systemImage: "gauge.with.dots.needle.67percent") }
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
