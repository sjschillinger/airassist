import SwiftUI
import ServiceManagement

struct GeneralPrefsView: View {
    let store: ThermalStore

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
