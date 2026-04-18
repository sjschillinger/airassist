import SwiftUI

struct MenuBarPopoverView: View {
    let store: ThermalStore
    var onDashboard: () -> Void    = {}
    var onPreferences: () -> Void  = {}
    var onQuit: () -> Void         = {}

    @AppStorage("tempUnit") private var tempUnitRaw: Int = TempUnit.celsius.rawValue
    private var unit: TempUnit { TempUnit(rawValue: tempUnitRaw) ?? .celsius }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sensorList
            Divider()
            throttleSection
            Divider()
            actionButtons
        }
        .frame(width: 280)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: AppStrings.MenuBar.defaultIcon)
                .font(.title2)
            Text(AppStrings.appName)
                .font(.headline)
            Spacer()
            pauseMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var pauseMenu: some View {
        Menu {
            if store.isPauseActive {
                Button("Resume now") { store.resumeThrottling() }
            } else {
                Section("Pause throttling for") {
                    Button("15 minutes") { store.pauseThrottling(for: 15 * 60) }
                    Button("1 hour")     { store.pauseThrottling(for: 60 * 60) }
                    Button("4 hours")    { store.pauseThrottling(for: 4 * 60 * 60) }
                    Button("Until quit") { store.pauseThrottling(for: nil) }
                }
            }
        } label: {
            Image(systemName: store.isPauseActive ? "pause.circle.fill" : "pause.circle")
                .foregroundStyle(store.isPauseActive ? .yellow : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.isPauseActive ? "Throttling paused" : "Pause throttling")
    }

    @ViewBuilder
    private var sensorList: some View {
        let groups = store.sensorsByCategory
        if groups.isEmpty {
            switch store.sensorService.readState {
            case .booting:
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading sensors…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            case .unavailable:
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Sensors unavailable")
                        .font(.caption).bold()
                    Text("macOS didn't return any thermal sensors. Re-launch Air Assist, and if it persists, check Preferences → Sensors for details.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            case .ok:
                EmptyView()   // won't hit — groups wouldn't be empty
            }
        } else {
            SensorListView(groups: groups,
                           thresholds: store.thresholds,
                           unit: unit)
                .frame(maxHeight: 260)
        }
    }

    @ViewBuilder
    private var throttleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: governorIcon).foregroundStyle(governorColor)
                Text(governorSummary).font(.caption).bold()
                Spacer()
                if !store.liveThrottledPIDs.isEmpty {
                    Text("\(store.liveThrottledPIDs.count) active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !store.liveThrottledPIDs.isEmpty {
                ForEach(store.liveThrottledPIDs.prefix(3).sorted { $0.duty < $1.duty }, id: \.pid) { item in
                    HStack {
                        Text("•  \(item.name)").lineLimit(1)
                        Spacer()
                        Text("\(Int((item.duty * 100).rounded()))%").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
                if store.liveThrottledPIDs.count > 3 {
                    Text("+ \(store.liveThrottledPIDs.count - 3) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var governorSummary: String {
        if store.isPauseActive {
            if let until = store.pausedUntil, until != .distantFuture {
                return "Paused · resumes \(relative(to: until))"
            }
            return "Paused"
        }
        if store.governorConfig.isOff && !store.throttleRules.enabled {
            return "Throttling: Off"
        }
        if store.governor.isTempThrottling || store.governor.isCPUThrottling {
            return "Governor active"
        }
        if !store.liveThrottledPIDs.isEmpty {
            return "Rules active"
        }
        return "Governor armed"
    }
    private var governorColor: Color {
        if store.isPauseActive { return .yellow }
        if store.governorConfig.isOff && !store.throttleRules.enabled { return .secondary }
        if store.governor.isTempThrottling || store.governor.isCPUThrottling { return .orange }
        return .green
    }
    private var governorIcon: String {
        if store.isPauseActive { return "pause.circle.fill" }
        if store.governor.isTempThrottling { return "thermometer.high" }
        if store.governor.isCPUThrottling { return "cpu" }
        return "gauge.with.dots.needle.67percent"
    }

    private func relative(to date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var actionButtons: some View {
        VStack(spacing: 0) {
            MenuBarButton(label: AppStrings.MenuBar.dashboard,
                          icon: "gauge.with.dots.needle.33percent") { onDashboard() }
            MenuBarButton(label: AppStrings.MenuBar.preferences,
                          icon: "gearshape") { onPreferences() }
            Divider()
                .padding(.vertical, 4)
            MenuBarButton(label: AppStrings.MenuBar.quit,
                          icon: "power",
                          role: .destructive) { onQuit() }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Menu-item-style button

private struct MenuBarButton: View {
    let label: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .modifier(HoverHighlight())
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .onHover { isHovered = $0 }
    }
}
