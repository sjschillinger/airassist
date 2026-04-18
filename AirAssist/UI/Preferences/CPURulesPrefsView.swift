import SwiftUI

/// Per-app throttling rules ("App Rules" tab).
/// Users pick a running process, pick a duty (% CPU they'd like it
/// to be allowed to use), and we duty-cycle it via SIGSTOP/SIGCONT.
struct CPURulesPrefsView: View {
    @Bindable var store: ThermalStore

    @State private var selectedRuleID: ThrottleRule.ID?
    @State private var showAddSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: Binding(
                    get: { store.throttleRules.enabled },
                    set: { store.setRulesEngineEnabled($0) }
                )) {
                    Text("Enable per-app rules")
                        .font(.headline)
                }
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Rule…", systemImage: "plus")
                }
            }

            Text("Rules apply SIGSTOP/SIGCONT duty cycling. 100% means no throttle; 50% means the app runs half the wall-clock time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if store.throttleRules.rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "tortoise",
                    description: Text("Add a rule to cap CPU usage of a specific app.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    TableColumn("Allowed CPU") { rule in
                        Text("\(Int((rule.duty * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .width(110)
                    TableColumn("Enabled") { rule in
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
                    .width(60)
                }
                .frame(minHeight: 180)

                HStack {
                    if let id = selectedRuleID,
                       let rule = store.throttleRules.rules.first(where: { $0.id == id }) {
                        editor(for: rule)
                    } else {
                        Text("Select a rule to edit")
                            .foregroundStyle(.secondary)
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
                    .disabled(selectedRuleID == nil)
                }
            }
        }
        .padding(16)
        .sheet(isPresented: $showAddSheet) {
            AddRuleSheet(store: store, isPresented: $showAddSheet)
        }
    }

    @ViewBuilder
    private func editor(for rule: ThrottleRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.displayName).font(.headline)
            HStack {
                Text("Allowed CPU")
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
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

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
                TableColumn("App") { p in
                    Text(p.displayName)
                }
                TableColumn("Process") { p in
                    Text(p.name).font(.caption).foregroundStyle(.secondary)
                }
                TableColumn("CPU%") { p in
                    Text("\(Int(p.cpuPercent.rounded()))%")
                        .monospacedDigit()
                }
                .width(60)
                TableColumn("PID") { p in
                    Text("\(p.id)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(60)
            }
            .frame(minHeight: 260)

            HStack {
                Text("Allowed CPU")
                Slider(value: $duty, in: 0.05...1.0, step: 0.05)
                    .frame(width: 200)
                Text("\(Int((duty * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
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
            // Prime CPU% (needs two snapshots for non-zero values)
            _ = store.processInspector.snapshot()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                processes = store.ruleEngine.availableProcesses()
            }
        }
    }
}
