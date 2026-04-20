import SwiftUI

/// Unified throttling preferences. Auto (governor) on top, per-app rules
/// below. Same page — they are two halves of one concept.
struct ThrottlingPrefsView: View {
    @Bindable var store: ThermalStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pauseBanner
                GovernorSection(store: store)
                Divider()
                RulesSection(store: store)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var pauseBanner: some View {
        if store.isPauseActive {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Throttling paused").font(.subheadline).bold()
                    if let until = store.pausedUntil, until != .distantFuture {
                        Text("Resumes \(until, style: .relative) from now")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Until you resume or quit the app")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Resume") { store.resumeThrottling() }
            }
            .padding(12)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Governor

private struct GovernorSection: View {
    @Bindable var store: ThermalStore

    /// CPU scale mode. When `.normalized`, slider and displays show 0–100%
    /// of total system capacity (1 core fully pegged on an 8-core machine
    /// reads 12.5%). When `.perCore`, we show the raw kernel-reported sum
    /// (8 cores fully pegged reads 800%) — matches `top`/Activity Monitor.
    /// Persisted as an AppStorage so it survives launches.
    @AppStorage("cpuCapScaleMode") private var scaleModeRaw: String = "normalized"
    private var scaleMode: CPUScaleMode {
        get { CPUScaleMode(rawValue: scaleModeRaw) ?? .normalized }
    }

    /// Cores visible to the kernel — used to convert between the two
    /// scales. `activeProcessorCount` tracks e-core park state on Apple
    /// Silicon, so "100% of system" honours the cores actually online.
    private var coreCount: Double {
        max(1, Double(ProcessInfo.processInfo.activeProcessorCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text("Automatic governor").font(.headline)
                Spacer()
                statusChip
            }

            Text("Automatically throttles top CPU processes when a sensor or total CPU usage crosses a cap.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("", selection: Binding(
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
            .labelsHidden()

            // Presets: one-click tuning.
            HStack(spacing: 6) {
                Text("Preset:").font(.caption).foregroundStyle(.secondary)
                ForEach(GovernorPreset.allCases) { preset in
                    Button(preset.label) {
                        store.governorConfig = preset.applied(to: store.governorConfig)
                    }
                    .controlSize(.small)
                    .help(preset.tagline)
                }
                Spacer()
            }

            if store.governorConfig.tempEnabled {
                tempSection
            }
            if store.governorConfig.cpuEnabled {
                cpuSection
            }
            if !store.governorConfig.isOff {
                targetingSection
                advancedSection
                previewSection
            }
        }
    }

    /// "Would get throttled" preview — shows exactly which processes the
    /// governor would pick *right now* under the current targeting settings,
    /// without needing to wait for a cap to breach. Lets the user test
    /// threshold tuning before it bites.
    @ViewBuilder
    private var previewSection: some View {
        let cfg = store.governorConfig
        let ruleCovered: Set<pid_t> = Set(
            store.ruleEngine.managedPIDs
        )
        let candidates = store.governor.lastTopProcesses
            .filter { $0.cpuPercent >= cfg.minCPUForTargeting }
            .filter { !ruleCovered.contains($0.id) }
            .prefix(cfg.maxTargets)
        GroupBox("Would get throttled now") {
            if candidates.isEmpty {
                Text("No process currently meets the targeting threshold. Lower “Consider processes ≥ …% CPU” to preview more candidates.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(candidates)) { p in
                        HStack(spacing: 8) {
                            Text(p.displayName).lineLimit(1)
                            Text(p.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("\(Int(p.cpuPercent))%")
                                .monospacedDigit().foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                    Text("Shown if a cap breached this instant. Live snapshot, updates every second.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var statusChip: some View {
        let isActive = store.governor.isTempThrottling || store.governor.isCPUThrottling
        let text: String
        let color: Color
        if store.isPauseActive      { text = "Paused"; color = .yellow }
        else if store.governorConfig.isOff { text = "Off"; color = .secondary }
        else if isActive            { text = "Throttling"; color = .orange }
        else                        { text = "Armed"; color = .green }
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var tempSection: some View {
        GroupBox("Temperature cap") {
            VStack(alignment: .leading, spacing: 6) {
                Slider(value: bind(\.maxTempC), in: 40...100, step: 1) {
                    Text("Max")
                } minimumValueLabel: { Text("40°C").font(.caption) }
                  maximumValueLabel: { Text("100°C").font(.caption) }
                HStack {
                    Text("Max: \(Int(store.governorConfig.maxTempC))°C").monospacedDigit()
                    Spacer()
                    if let hottest = store.enabledSensors.compactMap(\.currentValue).max() {
                        Text("now \(Int(hottest))°C")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.caption)
                Stepper(value: bind(\.tempHysteresisC), in: 1...20) {
                    Text("Hysteresis: \(Int(store.governorConfig.tempHysteresisC))°C")
                        .font(.caption)
                }
                Text("Apple Silicon begins its own thermal management in the mid-90s °C. Caps near 100°C overlap with that — set lower to intervene first.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cpuSection: some View {
        GroupBox("CPU cap") {
            VStack(alignment: .leading, spacing: 6) {
                // Scale-mode picker. Toggling this doesn't mutate the stored
                // config (which is always per-core under the hood) — it
                // only changes how the slider and current-value are shown.
                Picker("", selection: Binding(
                    get: { scaleMode },
                    set: { scaleModeRaw = $0.rawValue }
                )) {
                    Text("% of system").tag(CPUScaleMode.normalized)
                    Text("Per-core sum").tag(CPUScaleMode.perCore)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                cpuSlider
                HStack {
                    Text("Max: \(formatCPU(store.governorConfig.maxCPUPercent))").monospacedDigit()
                    Spacer()
                    Text("now \(formatCPU(currentTotalCPU))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
                cpuHysteresisStepper

                Text(scaleMode == .normalized
                     ? "100% = every core on this Mac fully used (\(Int(coreCount)) cores online)."
                     : "100% ≈ one core.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The slider's bounds and step depend on the scale mode. In normalized
    /// mode we cap at 100%; in per-core mode we cap at `coreCount * 100`.
    /// The underlying stored value is always per-core percent, so we
    /// convert in/out of the slider binding.
    @ViewBuilder
    private var cpuSlider: some View {
        switch scaleMode {
        case .normalized:
            Slider(value: normalizedMaxCPU, in: 5...100, step: 1) {
                Text("Max")
            } minimumValueLabel: { Text("5%").font(.caption) }
              maximumValueLabel: { Text("100%").font(.caption) }
        case .perCore:
            let ceiling = coreCount * 100
            Slider(value: bind(\.maxCPUPercent),
                   in: 50...ceiling,
                   step: 25) {
                Text("Max")
            } minimumValueLabel: { Text("50%").font(.caption) }
              maximumValueLabel: { Text("\(Int(ceiling))%").font(.caption) }
        }
    }

    /// Hysteresis uses the same scale as the max cap, so users don't flip
    /// between mental models when tuning. Stepper step size stays
    /// proportional to the scale.
    @ViewBuilder
    private var cpuHysteresisStepper: some View {
        switch scaleMode {
        case .normalized:
            let step = 1.0
            let bounds: ClosedRange<Double> = 1...50
            Stepper(value: normalizedHysteresis(step: step, bounds: bounds),
                    in: bounds, step: step) {
                Text("Hysteresis: \(formatCPU(store.governorConfig.cpuHysteresisPercent, forceSameModeAsMax: true))")
                    .font(.caption)
            }
        case .perCore:
            Stepper(value: bind(\.cpuHysteresisPercent), in: 10...400, step: 10) {
                Text("Hysteresis: \(Int(store.governorConfig.cpuHysteresisPercent))%")
                    .font(.caption)
            }
        }
    }

    // MARK: - Scale conversion helpers

    /// Slider binding in 0–100 "% of system" that maps to the stored
    /// per-core percent.
    private var normalizedMaxCPU: Binding<Double> {
        Binding(
            get: { store.governorConfig.maxCPUPercent / coreCount },
            set: { v in
                var c = store.governorConfig
                c.maxCPUPercent = (v * coreCount).rounded()
                store.governorConfig = c
            }
        )
    }

    private func normalizedHysteresis(step: Double, bounds: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { store.governorConfig.cpuHysteresisPercent / coreCount },
            set: { v in
                var c = store.governorConfig
                c.cpuHysteresisPercent = (v * coreCount).rounded()
                store.governorConfig = c
            }
        )
    }

    /// Format a per-core percent for display according to the active
    /// scale mode. Suffix always "%" — in normalized mode we divide by
    /// coreCount and show one decimal when small.
    private func formatCPU(_ perCorePercent: Double, forceSameModeAsMax: Bool = false) -> String {
        switch scaleMode {
        case .perCore:
            return "\(Int(perCorePercent.rounded()))%"
        case .normalized:
            let v = perCorePercent / coreCount
            if v < 10 { return String(format: "%.1f%%", v) }
            return "\(Int(v.rounded()))%"
        }
    }

    @ViewBuilder
    private var targetingSection: some View {
        GroupBox("Targeting") {
            VStack(alignment: .leading, spacing: 6) {
                Stepper(value: bindInt(\.maxTargets), in: 1...10) {
                    Text("Max simultaneous targets: \(store.governorConfig.maxTargets)")
                        .font(.caption)
                }
                Stepper(value: bind(\.minCPUForTargeting), in: 5...100, step: 5) {
                    Text("Consider processes ≥ \(Int(store.governorConfig.minCPUForTargeting))% CPU")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        GroupBox("Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: bindBool(\.onBatteryOnly)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Throttle only when on battery")
                        Text("When unchecked, caps apply on AC and battery alike. "
                             + "When checked, the governor stays armed-but-silent "
                             + "whenever a charger is connected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Toggle(isOn: bindBool(\.respectOSThermalState)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Factor in the OS thermal state")
                        Text("Lets macOS's own thermal pressure reading bias the "
                             + "duty cycle tighter when the system is already "
                             + "reporting heat stress. Recommended.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var currentTotalCPU: Double {
        store.governor.lastTotalCPUPercent
    }

    private func bindBool(_ path: WritableKeyPath<GovernorConfig, Bool>) -> Binding<Bool> {
        Binding(get: { store.governorConfig[keyPath: path] },
                set: { v in var c = store.governorConfig; c[keyPath: path] = v; store.governorConfig = c })
    }

    private func bind(_ path: WritableKeyPath<GovernorConfig, Double>) -> Binding<Double> {
        Binding(get: { store.governorConfig[keyPath: path] },
                set: { v in var c = store.governorConfig; c[keyPath: path] = v; store.governorConfig = c })
    }
    private func bindInt(_ path: WritableKeyPath<GovernorConfig, Int>) -> Binding<Int> {
        Binding(get: { store.governorConfig[keyPath: path] },
                set: { v in var c = store.governorConfig; c[keyPath: path] = v; store.governorConfig = c })
    }
}

/// Two ways of expressing CPU usage. Stored as a raw string in
/// AppStorage. `.normalized` is 0–100% of total system capacity;
/// `.perCore` is the raw sum-across-cores number (matches Activity
/// Monitor and the kernel's own reporting).
enum CPUScaleMode: String, Hashable {
    case normalized
    case perCore
}

// MARK: - Rules

private struct RulesSection: View {
    @Bindable var store: ThermalStore
    @State private var selectedRuleID: ThrottleRule.ID?
    @State private var showAddSheet: Bool = false

    /// Format "3m 20s" / "45s" / "1h 12m". Uses minutes once past a minute
    /// and drops seconds once past an hour — matches the precision users
    /// actually care about ("was it seconds or minutes?").
    fileprivate static func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let m = total / 60, rem = total % 60
            return rem == 0 ? "\(m)m" : "\(m)m \(rem)s"
        }
        let h = total / 3600, m = (total % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "tortoise")
                Text("Per-app rules").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { store.throttleRules.enabled },
                    set: { store.setRulesEngineEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
            }

            Text("Fixed caps for specific apps. 100% = no throttle, 50% = runs half the wall-clock time.")
                .font(.caption).foregroundStyle(.secondary)

            if store.throttleRules.rules.isEmpty {
                EmptyRulesView(store: store, onAdd: { showAddSheet = true })
            } else {
                Table(store.throttleRules.rules, selection: $selectedRuleID) {
                    TableColumn("App") { rule in
                        HStack {
                            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.isEnabled ? .green : .secondary)
                            Text(rule.displayName)
                            if store.liveThrottledPIDs.contains(where: { $0.name == rule.displayName }) {
                                Text("live")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    TableColumn("Allowed") { rule in
                        Text("\(Int((rule.duty * 100).rounded()))%").monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Today") { rule in
                        let s = store.ruleEngine.stats[rule.id]
                        if let s, s.fires > 0 {
                            Text("\(s.fires)× · \(Self.formatDuration(s.throttleSeconds))")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .help("Fired \(s.fires) time\(s.fires == 1 ? "" : "s") today, total \(Self.formatDuration(s.throttleSeconds)) of active throttling")
                        } else {
                            Text("—").foregroundStyle(.secondary.opacity(0.5))
                        }
                    }
                    .width(110)
                    TableColumn("On") { rule in
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { newVal in
                                var cfg = store.throttleRules
                                if let i = cfg.rules.firstIndex(where: { $0.id == rule.id }) {
                                    cfg.rules[i].isEnabled = newVal
                                    store.throttleRules = cfg
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(40)
                }
                .frame(minHeight: 160)

                HStack {
                    if let id = selectedRuleID,
                       let rule = store.throttleRules.rules.first(where: { $0.id == id }) {
                        ruleEditor(rule)
                    } else {
                        Text("Select a rule to edit its cap")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        if let id = selectedRuleID {
                            store.removeRule(id: id)
                            selectedRuleID = nil
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(selectedRuleID == nil)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddRuleSheet(store: store, isPresented: $showAddSheet)
        }
    }

    @ViewBuilder
    private func ruleEditor(_ rule: ThrottleRule) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.displayName).font(.subheadline).bold()
            HStack {
                Slider(value: Binding(
                    get: { rule.duty },
                    set: { newDuty in
                        var cfg = store.throttleRules
                        if let i = cfg.rules.firstIndex(where: { $0.id == rule.id }) {
                            cfg.rules[i].duty = newDuty
                            store.throttleRules = cfg
                        }
                    }
                ), in: 0.05...1.0, step: 0.05)
                .frame(width: 200)
                Text("\(Int((rule.duty * 100).rounded()))%")
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Empty-rules state with smart suggestions

/// Shown when the user has no throttle rules yet. Scans the governor's
/// last top-CPU snapshot for processes whose names match known hot-running
/// apps (Electron helpers, Chrome renderers, etc.) and surfaces them as
/// one-click "Throttle at 50%" suggestions.
private struct EmptyRulesView: View {
    let store: ThermalStore
    let onAdd: () -> Void

    /// Substrings that identify processes commonly worth throttling.
    /// Matched case-insensitively against the executable name.
    private static let hotAppPatterns: [String] = [
        "Helper", "Electron", "renderer", "chrome",
        "slack", "discord", "notion", "spotify", "figma",
        "teams", "zoom", "code", "docker",
    ]

    private var suggestions: [RunningProcess] {
        let seen = Set(store.throttleRules.rules.map(\.id))
        // Primary signal: apps that have sustained high CPU for half the
        // rolling window. Governed by ThermalGovernor's rolling buffer.
        let sustained = store.governor.sustainedHighCPUCandidates
            .filter { !seen.contains(ThrottleRule.key(for: $0)) }
        if !sustained.isEmpty {
            return Array(sustained.prefix(5))
        }
        // Fallback: name-pattern heuristic on the current top snapshot. Used
        // before the rolling buffer has accumulated enough data (first ~15s
        // after launch) and on quiet systems where nothing is sustained.
        let procs = store.governor.lastTopProcesses
        return procs
            .filter { p in
                Self.hotAppPatterns.contains { p.name.localizedCaseInsensitiveContains($0) }
            }
            .filter { !seen.contains(ThrottleRule.key(for: $0)) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("No rules yet", systemImage: "tortoise")
            } description: {
                Text("Cap how much CPU a specific app can use. 100% means no throttle; 50% means it runs half the wall-clock time.")
            } actions: {
                Button("Add Rule…", action: onAdd).controlSize(.regular)
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggestions based on what's running")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(suggestions) { p in
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.displayName).font(.subheadline)
                                Text("\(p.name) · \(Int(p.cpuPercent))% CPU")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cap at 50%") {
                                store.upsertRule(for: p, duty: 0.5)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

// Re-expose AddRuleSheet from the old CPURulesPrefsView. That file keeps it
// file-private, so we define a fresh one here.
private struct AddRuleSheet: View {
    let store: ThermalStore
    @Binding var isPresented: Bool

    @State private var processes: [RunningProcess] = []
    @State private var selectedPID: pid_t?
    @State private var duty: Double = 0.5
    @State private var filterText: String = ""

    var filtered: [RunningProcess] {
        let base = processes
            .filter { $0.cpuPercent > 0 || !$0.name.isEmpty }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        guard !filterText.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(filterText) ||
            $0.displayName.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Throttle Rule").font(.headline)
            TextField("Search…", text: $filterText)
                .textFieldStyle(.roundedBorder)
            Table(filtered, selection: $selectedPID) {
                TableColumn("App")     { Text($0.displayName) }
                TableColumn("Process") { Text($0.name).font(.caption).foregroundStyle(.secondary) }
                TableColumn("CPU%")    { Text("\(Int($0.cpuPercent.rounded()))%").monospacedDigit() }
                    .width(60)
                TableColumn("PID")     { Text("\($0.id)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(60)
            }
            .frame(minHeight: 260)

            HStack {
                Text("Allowed CPU")
                Slider(value: $duty, in: 0.05...1.0, step: 0.05).frame(width: 200)
                Text("\(Int((duty * 100).rounded()))%")
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    if let pid = selectedPID,
                       let p = processes.first(where: { $0.id == pid }) {
                        store.upsertRule(for: p, duty: duty)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPID == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .onAppear {
            _ = store.processInspector.snapshot()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                processes = store.ruleEngine.availableProcesses()
            }
        }
    }
}
