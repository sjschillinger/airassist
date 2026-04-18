import SwiftUI

/// System-wide cap settings. User picks a cap mode and thresholds; the
/// `ThermalGovernor` enforces them by throttling top-CPU processes.
struct GovernorPrefsView: View {
    @Bindable var store: ThermalStore

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Governor mode", selection: Binding(
                    get: { store.governorConfig.mode },
                    set: { new in
                        var c = store.governorConfig
                        c.mode = new
                        store.governorConfig = c
                    }
                )) {
                    ForEach(GovernorMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.governorConfig.tempEnabled {
                Section("Temperature cap") {
                    Slider(value: Binding(
                        get: { store.governorConfig.maxTempC },
                        set: { updateTempCap($0) }
                    ), in: 40...110, step: 1) {
                        Text("Max temperature")
                    } minimumValueLabel: {
                        Text("40°C")
                    } maximumValueLabel: {
                        Text("110°C")
                    }
                    HStack {
                        Text("Max: \(Int(store.governorConfig.maxTempC))°C")
                        Spacer()
                        Text("Release at \(Int(store.governorConfig.maxTempC - store.governorConfig.tempHysteresisC))°C")
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()

                    Stepper(value: Binding(
                        get: { store.governorConfig.tempHysteresisC },
                        set: { updateTempHyst($0) }
                    ), in: 1...20) {
                        Text("Hysteresis: \(Int(store.governorConfig.tempHysteresisC))°C")
                    }
                }
            }

            if store.governorConfig.cpuEnabled {
                Section("CPU cap") {
                    Slider(value: Binding(
                        get: { store.governorConfig.maxCPUPercent },
                        set: { updateCPUCap($0) }
                    ), in: 50...1600, step: 25) {
                        Text("Max CPU%")
                    } minimumValueLabel: {
                        Text("50%")
                    } maximumValueLabel: {
                        Text("1600%")
                    }
                    HStack {
                        Text("Max: \(Int(store.governorConfig.maxCPUPercent))%")
                        Spacer()
                        Text("Release at \(Int(store.governorConfig.maxCPUPercent - store.governorConfig.cpuHysteresisPercent))%")
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()

                    Stepper(value: Binding(
                        get: { store.governorConfig.cpuHysteresisPercent },
                        set: { updateCPUHyst($0) }
                    ), in: 10...400, step: 10) {
                        Text("Hysteresis: \(Int(store.governorConfig.cpuHysteresisPercent))%")
                    }

                    Text("100% ≈ one core. 400% ≈ four cores saturated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.governorConfig.isOff {
                Section("Targeting") {
                    Stepper(value: Binding(
                        get: { store.governorConfig.maxTargets },
                        set: { updateTargets($0) }
                    ), in: 1...10) {
                        Text("Max simultaneous targets: \(store.governorConfig.maxTargets)")
                    }
                    Stepper(value: Binding(
                        get: { store.governorConfig.minCPUForTargeting },
                        set: { updateMinCPU($0) }
                    ), in: 5...100, step: 5) {
                        Text("Consider processes using ≥ \(Int(store.governorConfig.minCPUForTargeting))% CPU")
                    }
                }

                Section("Status") {
                    LabeledContent("Temperature throttling") {
                        Text(store.governor.isTempThrottling ? "Active" : "Idle")
                            .foregroundStyle(store.governor.isTempThrottling ? .orange : .secondary)
                    }
                    LabeledContent("CPU throttling") {
                        Text(store.governor.isCPUThrottling ? "Active" : "Idle")
                            .foregroundStyle(store.governor.isCPUThrottling ? .orange : .secondary)
                    }
                    LabeledContent("Currently throttled") {
                        Text("\(store.liveThrottledPIDs.count) process\(store.liveThrottledPIDs.count == 1 ? "" : "es")")
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(0)
    }

    private var modeDescription: String {
        switch store.governorConfig.mode {
        case .off:         return "Governor disabled. No system-wide throttling."
        case .temperature: return "Throttle top CPU processes when any sensor exceeds the temperature cap."
        case .cpu:         return "Throttle top CPU processes when total user CPU usage exceeds the cap."
        case .both:        return "Enforce whichever cap is breached first."
        }
    }

    private func updateTempCap(_ v: Double)  { var c = store.governorConfig; c.maxTempC = v;           store.governorConfig = c }
    private func updateTempHyst(_ v: Double) { var c = store.governorConfig; c.tempHysteresisC = v;    store.governorConfig = c }
    private func updateCPUCap(_ v: Double)   { var c = store.governorConfig; c.maxCPUPercent = v;      store.governorConfig = c }
    private func updateCPUHyst(_ v: Double)  { var c = store.governorConfig; c.cpuHysteresisPercent = v; store.governorConfig = c }
    private func updateTargets(_ v: Int)     { var c = store.governorConfig; c.maxTargets = v;          store.governorConfig = c }
    private func updateMinCPU(_ v: Double)   { var c = store.governorConfig; c.minCPUForTargeting = v;  store.governorConfig = c }
}
