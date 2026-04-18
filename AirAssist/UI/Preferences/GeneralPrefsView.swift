import SwiftUI
import ServiceManagement

struct GeneralPrefsView: View {
    @Bindable var store: ThermalStore

    @AppStorage("showDockIcon")    private var showDockIcon: Bool   = false
    @AppStorage("updateInterval")  private var updateInterval: Double = 2.0

    // Stay Awake — stored as two halves so UserDefaults stays forward-
    // compatible if we add more mode variants. `stayAwake.mode` is the
    // persisted tag; `stayAwake.displayTimeoutMinutes` feeds both the
    // menu-bar submenu and the `.displayThenSystem` variant.
    @AppStorage("stayAwake.displayTimeoutMinutes")
    private var displayTimeoutMinutes: Int = 10

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

            Section("Stay Awake") {
                LabeledContent("Mode") {
                    Picker("", selection: stayAwakeModeBinding) {
                        Text("Off").tag(StayAwakeMode.off)
                        Text("Keep system awake").tag(StayAwakeMode.system)
                        Text("Keep system & display awake").tag(StayAwakeMode.display)
                        Text("Display on, then system only").tag(StayAwakeMode.displayThenSystem)
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }

                if currentModeTag == .displayThenSystem {
                    LabeledContent("Turn display off after") {
                        HStack(spacing: 6) {
                            Stepper(value: $displayTimeoutMinutes, in: 1...240) {
                                Text("\(displayTimeoutMinutes) min")
                                    .font(.system(.body).monospacedDigit())
                            }
                            .onChange(of: displayTimeoutMinutes) { _, newValue in
                                // Re-apply the mode so the new timeout takes effect immediately.
                                if case .displayThenSystem = store.stayAwake.currentMode {
                                    store.setStayAwakeMode(.displayThenSystem(minutes: newValue))
                                }
                            }
                        }
                    }
                    if let remaining = store.stayAwake.displayTimerRemaining, remaining > 0 {
                        LabeledContent("Display sleeps in") {
                            Text(formatCountdown(remaining))
                                .font(.system(.body).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(stayAwakeExplanation)
                    .font(.caption).foregroundStyle(.secondary)
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

    // MARK: - Stay Awake bindings

    /// Tag-only enum for the picker. Keeping the minutes payload out of
    /// the picker selection avoids every stepper change rebuilding the
    /// Picker's identity.
    private enum StayAwakeMode: String, Hashable {
        case off, system, display, displayThenSystem
    }

    private var currentModeTag: StayAwakeMode {
        switch store.stayAwake.currentMode {
        case .off:                return .off
        case .system:             return .system
        case .display:            return .display
        case .displayThenSystem:  return .displayThenSystem
        }
    }

    private var stayAwakeModeBinding: Binding<StayAwakeMode> {
        Binding(
            get: { currentModeTag },
            set: { tag in
                switch tag {
                case .off:                store.setStayAwakeMode(.off)
                case .system:             store.setStayAwakeMode(.system)
                case .display:            store.setStayAwakeMode(.display)
                case .displayThenSystem:  store.setStayAwakeMode(.displayThenSystem(minutes: displayTimeoutMinutes))
                }
            }
        )
    }

    private var stayAwakeExplanation: String {
        switch currentModeTag {
        case .off:
            return "The Mac follows its normal Energy Saver settings."
        case .system:
            return "Prevents idle sleep. The display can still turn off on its normal schedule — useful for downloads, renders, or long builds."
        case .display:
            return "Prevents both system and display sleep. Think of it as caffeinate with the screen locked on."
        case .displayThenSystem:
            return "The screen stays on for the configured minutes, then sleeps while background work continues. Great for presentations or long reads that eventually need to go idle."
        }
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
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
