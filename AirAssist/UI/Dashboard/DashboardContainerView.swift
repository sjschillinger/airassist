import SwiftUI

/// Tabbed container for the main AirAssist window. Hosts the live Dashboard
/// and the time-series History view. New tabs (events log, rule editor
/// detail, etc.) slot in here.
struct DashboardContainerView: View {
    @Bindable var store: ThermalStore

    var body: some View {
        TabView {
            DashboardView(store: store)
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                }
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "chart.xyaxis.line")
                }
        }
        .padding(.top, 4)
    }
}
