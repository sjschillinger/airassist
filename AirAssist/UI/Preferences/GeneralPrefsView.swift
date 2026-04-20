import SwiftUI
import ServiceManagement

struct GeneralPrefsView: View {
    @Bindable var store: ThermalStore

    @AppStorage("showDockIcon")    private var showDockIcon: Bool   = false
    @AppStorage("updateInterval")  private var updateInterval: Double = 1.0

    // Stay Awake — stored as two halves so UserDefaults stays forward-
    // compatible if we add more mode variants. `stayAwake.mode` is the
    // persisted tag; `stayAwake.displayTimeoutMinutes` feeds both the
    // menu-bar submenu and the `.displayThenSystem` variant.
    @AppStorage("stayAwake.displayTimeoutMinutes")
    private var displayTimeoutMinutes: Int = 10

    @State private var loginStatus: SMAppService.Status = SMAppService.mainApp.status

    // Mirror the hotkey service's persisted flag + battery-aware flags so
    // SwiftUI re-renders when the user toggles them. These services own the
    // authoritative state — bindings read/write through them, not through
    // @AppStorage directly.
    @State private var hotkeyEnabled: Bool = GlobalHotkeyService.shared.isEnabled
    @State private var batteryAwareEnabled: Bool = false
    @State private var batteryAwareOnBattery: ThresholdPreset = .aggressive
    @State private var batteryAwareOnPowered: ThresholdPreset = .balanced

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
                            Button("15 minutes")     { store.pauseThrottling(for: 15 * 60) }
                                .help("Release every throttled PID and hold off for 15 minutes. Governor and rules resume automatically when the timer expires.")
                            Button("1 hour")         { store.pauseThrottling(for: 60 * 60) }
                            Button("4 hours")        { store.pauseThrottling(for: 4 * 60 * 60) }
                            Button("Until quit")     { store.pauseThrottling(for: nil) }
                                .help("Pause indefinitely — until you click Resume, or relaunch the app.")
                        }
                        .controlSize(.small)
                    }
                    Text("Temporarily stop both the governor and per-app rules. Useful for gaming or rendering sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Global hotkey ⌘⌥P") {
                    Toggle("", isOn: Binding(
                        get: { hotkeyEnabled },
                        set: { on in
                            hotkeyEnabled = on
                            GlobalHotkeyService.shared.isEnabled = on
                        }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Enable global pause hotkey Command Option P")
                }
                Text("Toggle pause/resume from any app. Carbon-based — no Accessibility permission required.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Battery-aware thresholds") {
                LabeledContent("Enabled") {
                    Toggle("", isOn: Binding(
                        get: { batteryAwareEnabled },
                        set: { on in
                            batteryAwareEnabled = on
                            store.batteryAware.isEnabled = on
                        }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Enable battery-aware threshold swapping")
                }
                if batteryAwareEnabled {
                    LabeledContent("On battery") {
                        Picker("", selection: Binding(
                            get: { batteryAwareOnBattery },
                            set: { p in
                                batteryAwareOnBattery = p
                                store.batteryAware.onBatteryPreset = p
                            }
                        )) {
                            ForEach(ThresholdPreset.allCases) { p in
                                Text(p.label).tag(p)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel("Threshold preset while on battery")
                    }
                    LabeledContent("On AC") {
                        Picker("", selection: Binding(
                            get: { batteryAwareOnPowered },
                            set: { p in
                                batteryAwareOnPowered = p
                                store.batteryAware.onPoweredPreset = p
                            }
                        )) {
                            ForEach(ThresholdPreset.allCases) { p in
                                Text(p.label).tag(p)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel("Threshold preset while on AC power")
                    }
                }
                Text("Swaps your sensor thresholds based on power source. Only the warm/hot color bands change — governor caps and per-app rules are untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Stay Awake") {
                LabeledContent("Mode") {
                    Picker("", selection: stayAwakeModeBinding) {
                        Text("Off").tag(StayAwakeMode.off)
                        Text("Keep system awake").tag(StayAwakeMode.system)
                            .help("Prevents idle sleep. Display follows its normal schedule. Like `caffeinate -i`.")
                        Text("Keep system & display awake").tag(StayAwakeMode.display)
                            .help("Prevents both system and display sleep. Like `caffeinate -id`.")
                        Text("Display on, then system only").tag(StayAwakeMode.displayThenSystem)
                            .help("Holds the display awake for the configured minutes, then lets it sleep while the system itself stays up for background work.")
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    .accessibilityLabel("Stay awake mode")
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

                if currentModeTag != .off {
                    LabeledContent("When the display sleeps") {
                        Toggle(isOn: releaseOnScreenSleepBinding) {
                            Text("Release Stay Awake")
                        }
                        .toggleStyle(.switch)
                        .help("When on, Air Assist drops the Stay Awake "
                              + "assertion whenever the display sleeps — "
                              + "lid close without an external display, "
                              + "screen lock, or an idle display-off — "
                              + "and re-takes it when the display wakes. "
                              + "Useful if you use Stay Awake for long "
                              + "unattended jobs but want the machine to "
                              + "rest while you're not at it.")
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

            Section("Updates") {
                LabeledContent("Check automatically") {
                    Toggle("", isOn: Binding(
                        get: { UpdateCheckService.shared.automaticChecksEnabled },
                        set: { UpdateCheckService.shared.automaticChecksEnabled = $0 }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Check for updates automatically every day")
                }
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if let v = UpdateCheckService.shared.latestVersion {
                            Text("Version \(v) available").foregroundStyle(.orange)
                            Button("Open Release Page") {
                                UpdateCheckService.shared.openReleasePage()
                            }
                            .controlSize(.small)
                        } else if let last = UpdateCheckService.shared.lastCheckedAt {
                            Text("Up to date — last checked \(last, style: .relative) ago")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Never checked").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Check Now") {
                            Task { @MainActor in
                                await UpdateCheckService.shared.checkNow()
                            }
                        }
                        .controlSize(.small)
                        .disabled(UpdateCheckService.shared.isChecking)
                    }
                }
                Text("One daily request to api.github.com to see if a newer release exists. No telemetry, no personal data — just the version tag. Turning this off leaves the \"Check for Updates…\" menu item working for manual checks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Support") {
                LabeledContent("Diagnostics") {
                    Button("Export Diagnostic Bundle…") {
                        DiagnosticBundle.exportInteractively(store: store)
                    }
                }
                Text("Bundles your current configuration, live throttle state, and recent thermal history into a single .zip you can attach to a GitHub issue. Nothing is uploaded — the file is saved locally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginStatus = LaunchAtLoginService.shared.status
            hotkeyEnabled = GlobalHotkeyService.shared.isEnabled
            batteryAwareEnabled = store.batteryAware.isEnabled
            batteryAwareOnBattery = store.batteryAware.onBatteryPreset
            batteryAwareOnPowered = store.batteryAware.onPoweredPreset
            // Re-read status on every appearance so the toggle reflects
            // out-of-band changes the user made in System Settings.
            LaunchAtLoginService.shared.refresh()
        }
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

    private var releaseOnScreenSleepBinding: Binding<Bool> {
        Binding(
            get: { store.stayAwake.releaseOnScreenSleep },
            set: { store.stayAwake.releaseOnScreenSleep = $0 }
        )
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
        let base: String
        switch currentModeTag {
        case .off:
            return "The Mac follows its normal Energy Saver settings."
        case .system:
            base = "Prevents idle sleep. The display can still turn off on its normal schedule — useful for downloads, renders, or long builds."
        case .display:
            base = "Prevents both system and display sleep. Think of it as caffeinate with the screen locked on."
        case .displayThenSystem:
            base = "The screen stays on for the configured minutes, then sleeps while background work continues. Great for presentations or long reads that eventually need to go idle."
        }
        // Clamshell caveat. Apple Silicon portables without an external
        // display go to sleep on lid-close regardless of which assertion
        // we hold — PreventUserIdle{System,Display}Sleep blocks idle-
        // initiated sleep, not clamshell-initiated sleep. We empirically
        // verified this on 2026-04-19 (#37 runbook). Surface it so users
        // don't expect "Stay Awake" to keep a closed-lid Air running.
        return base + " Note: closing the lid still sleeps the Mac unless an external display is connected — that's a macOS-level rule Stay Awake can't override."
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
                // Route through LaunchAtLoginService so errors surface to the
                // user and `.requiresApproval` opens System Settings. The
                // service updates `loginStatus` via the observer registered
                // in `.onAppear`.
                loginStatus = LaunchAtLoginService.shared.setEnabled(enable)
            }
        )
    }
}
