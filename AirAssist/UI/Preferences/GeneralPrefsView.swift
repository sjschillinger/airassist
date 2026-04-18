import SwiftUI
import ServiceManagement

struct GeneralPrefsView: View {
    @Bindable var store: ThermalStore

    @AppStorage("showDockIcon")    private var showDockIcon: Bool   = false
    @AppStorage("updateInterval")  private var updateInterval: Double = 2.0

    @State private var loginStatus: SMAppService.Status = SMAppService.mainApp.status

    private let intervalOptions: [(label: String, seconds: Double)] = [
        ("1 second",  1),
        ("2 seconds", 2),
        ("5 seconds", 5),
        ("10 seconds", 10),
        ("30 seconds", 30),
    ]

    var body: some View {
        Form {
            Section("Startup") {
                LabeledContent(AppStrings.Preferences.launchAtLogin) {
                    Toggle("", isOn: launchAtLoginBinding)
                        .labelsHidden()
                }
                LabeledContent(AppStrings.Preferences.showDockIcon) {
                    Toggle("", isOn: $showDockIcon)
                        .labelsHidden()
                        .onChange(of: showDockIcon) { _, show in
                            NSApp.setActivationPolicy(show ? .regular : .accessory)
                        }
                }
            }

            Section("Throttling") {
                if store.isPauseActive {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Text("Paused").foregroundStyle(.yellow)
                            if let until = store.pausedUntil, until != .distantFuture {
                                Text("· resumes \(until, style: .relative) from now")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Resume now") { store.resumeThrottling() }
                } else {
                    LabeledContent("Pause for") {
                        HStack(spacing: 6) {
                            Button("15 min")         { store.pauseThrottling(for: 15 * 60) }
                            Button("1 hour")         { store.pauseThrottling(for: 60 * 60) }
                            Button("4 hours")        { store.pauseThrottling(for: 4 * 60 * 60) }
                            Button("Until quit")     { store.pauseThrottling(for: nil) }
                        }
                        .controlSize(.small)
                    }
                    Text("Temporarily stop both the governor and per-app rules. Useful for gaming or rendering sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Monitoring") {
                LabeledContent(AppStrings.Preferences.updateInterval) {
                    Picker("", selection: Binding(
                        get: { updateInterval },
                        set: {
                            updateInterval = $0
                            store.sensorService.pollIntervalSeconds = $0
                        }
                    )) {
                        ForEach(intervalOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginStatus = SMAppService.mainApp.status
                } catch {
                    // Silently fails in debug builds run from DerivedData
                    loginStatus = SMAppService.mainApp.status
                }
            }
        )
    }
}
