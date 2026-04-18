import SwiftUI

struct MenuBarPopoverView: View {
    let store: ThermalStore
    var onDashboard: () -> Void    = {}
    var onPreferences: () -> Void  = {}
    var onQuit: () -> Void         = {}

    // Unit preference — wired to AppStorage in Step 8; defaults to °C
    @AppStorage("tempUnit") private var tempUnitRaw: Int = TempUnit.celsius.rawValue
    private var unit: TempUnit { TempUnit(rawValue: tempUnitRaw) ?? .celsius }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sensorList
            Divider()
            actionButtons
        }
        .frame(width: 260)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: AppStrings.MenuBar.defaultIcon)
                .font(.title2)
            Text(AppStrings.appName)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sensorList: some View {
        let groups = store.sensorsByCategory
        if groups.isEmpty {
            Text("Reading sensors…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else {
            SensorListView(groups: groups,
                           thresholds: store.thresholds,
                           unit: unit)
                .frame(maxHeight: 280)
        }
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
