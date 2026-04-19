import AppKit
import SwiftUI

/// One-time onboarding sheet (#39). Runs after `FirstRunDisclosure`
/// has been acknowledged, so the user has already agreed to the risk
/// surface — this window is purely getting-started guidance:
///
///   1. Explain what the menu bar icon is and where preferences live
///   2. Let the user pick a threshold preset in one click
///   3. Offer to enable a handful of starter rules
///   4. Surface the global hotkey and battery-aware toggles as
///      discoverable options (not hidden in prefs)
///
/// Idempotent via UserDefaults key `onboarding.seenVersion`. Bump
/// `currentVersion` when the onboarding content materially changes and
/// you want to re-prompt. Does not block the menu bar — the window is
/// a standalone NSWindow, not modal.
@MainActor
enum OnboardingWindow {
    private static let seenKey = "onboarding.seenVersion"
    private static let currentVersion = 1

    private static var windowController: NSWindowController?

    static func presentIfNeeded(store: ThermalStore) {
        let seen = UserDefaults.standard.integer(forKey: seenKey)
        guard seen < currentVersion else { return }
        present(store: store, markSeen: true)
    }

    /// Explicit open (from a future "Show welcome again" menu entry).
    static func present(store: ThermalStore, markSeen: Bool) {
        if let wc = windowController, let w = wc.window {
            // Activate first so the window actually comes to the front
            // on an LSUIElement app — see PreferencesWindowController
            // for rationale.
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(store: store, onDone: {
            if markSeen {
                UserDefaults.standard.set(currentVersion, forKey: seenKey)
            }
            windowController?.close()
            windowController = nil
        })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to Air Assist"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        let wc = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        windowController = wc
    }
}

// MARK: - SwiftUI body

private struct OnboardingView: View {
    let store: ThermalStore
    let onDone: () -> Void

    @State private var selectedPreset: ThresholdPreset = .balanced
    @State private var enabledTemplates: Set<String> = []
    @State private var hotkeyEnabled: Bool = GlobalHotkeyService.shared.isEnabled
    @State private var batteryAwareEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                section("1. Menu bar icon") {
                    Text("Air Assist lives in your menu bar — click it for the live thermal popover, or right-click for the quick menu. Preferences are in the popover's gear icon.")
                        .foregroundStyle(.secondary)
                }

                section("2. How warm is \"warm\"?") {
                    Text("Pick a threshold profile. You can fine-tune individual numbers in Preferences later.")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedPreset) {
                        ForEach(ThresholdPreset.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(selectedPreset.tagline).font(.caption).foregroundStyle(.secondary)
                }

                section("3. Throttle common offenders") {
                    Text("These aren't enabled automatically. Toggle any that you actually run.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(RuleTemplates.all, id: \.id) { t in
                            Toggle(isOn: Binding(
                                get: { enabledTemplates.contains(t.id) },
                                set: { on in
                                    if on { enabledTemplates.insert(t.id) }
                                    else  { enabledTemplates.remove(t.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.displayName)
                                    Text(t.rationale).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                section("4. Optional") {
                    Toggle("Global hotkey ⌘⌥P to pause/resume", isOn: $hotkeyEnabled)
                    Toggle("Use stricter thresholds while on battery", isOn: $batteryAwareEnabled)
                }

                HStack {
                    // Esc dismisses without applying the onboarding choices.
                    // We still mark the onboarding seen so re-launch doesn't
                    // nag — if the user wants to revisit, there will be an
                    // explicit "Show welcome again" entry (present() call).
                    Button("Skip") { onDone() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Get started") { apply() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Air Assist")
                .font(.largeTitle).fontWeight(.semibold)
            Text("A two-minute setup. Nothing throttles until you enable it.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func apply() {
        // Thresholds
        let settings = selectedPreset.settings
        store.thresholds = settings
        ThresholdPersistence.save(settings)

        // Rule templates — insert as enabled, keep rules engine enabled iff
        // user selected any.
        if !enabledTemplates.isEmpty {
            var cfg = store.throttleRules
            for t in RuleTemplates.all where enabledTemplates.contains(t.id) {
                let rule = RuleTemplates.makeRule(from: t, enabled: true)
                if let idx = cfg.rules.firstIndex(where: { $0.id == rule.id }) {
                    cfg.rules[idx] = rule
                } else {
                    cfg.rules.append(rule)
                }
            }
            cfg.enabled = true
            store.throttleRules = cfg
        }

        GlobalHotkeyService.shared.isEnabled = hotkeyEnabled
        store.batteryAware.isEnabled = batteryAwareEnabled

        onDone()
    }
}
