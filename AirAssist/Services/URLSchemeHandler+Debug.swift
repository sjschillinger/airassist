import Foundation
import AppKit
import os

// Debug-only URL-scheme endpoints. Exist to make the runtime-safety
// test suite (`AirAssistIntegrationTests`) fully scriptable — so the
// manual runbooks under `scripts/manual-tests/` become unattended
// `xcodebuild test` invocations.
//
// **Compiled out of Release builds** via `#if DEBUG`. The DEBUG flag
// comes from `SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG` in
// project.yml (only the Debug config sets it), so shipping binaries
// never expose these endpoints.
//
// Design rules for every debug endpoint here:
//   • Must write to a caller-supplied absolute path (NSSavePanel
//     machinery bypassed entirely — tests can't click).
//   • Must be idempotent and fast enough to poll.
//   • Must never prompt a modal.
//
// Public surface:
//
//   airassist://debug/export-state?to=<absolute-file-path>
//       Writes live state as JSON to `to`. Similar to the
//       Support → Export Diagnostic Bundle flow but just the one
//       `live-state.json` file, no save panel, no zip.
//
//   airassist://debug/stay-awake?mode=off|system|display|displayThenSystem
//       Sets the Stay-Awake mode non-interactively. `displayThenSystem`
//       uses a 1-minute fallback timeout so `pmset -g assertions` can
//       be polled shortly after.
//
//   airassist://debug/seed-rule?bundle=<id>&duty=<0..1>&enabled=true[&keyType=bundle|name]
//       Upserts a rule into the live rules config — also flips the
//       rule engine on so the rule actually fires. The UI would make
//       you drill into Preferences; this is a one-call equivalent.
//       `keyType=name` seeds the rule keyed by executable name instead
//       of bundle ID, matching processes that have no Info.plist bundle
//       (shell-spawned /usr/bin/yes, etc.).
//
//   airassist://debug/clear-rules
//       Wipes every rule and disables the engine. Reset hook for test
//       setUp / tearDown.
//
//   airassist://debug/ping?to=<path>
//       Writes "pong\n<ISO8601-now>\n" to the path. Used by tests to
//       confirm the app is running and the URL-scheme channel is live
//       before firing real work. No side effects.
//
//   airassist://debug/open-dashboard
//   airassist://debug/open-preferences
//       Opens the Dashboard / Preferences window non-interactively. Needed
//       by the a11y UITest suite — XCUITest can't click an NSStatusItem
//       reliably on a menu-bar-only (LSUIElement) app.
//
// The endpoints are all under `airassist://debug/...` so they can't
// be confused with the production surface that Shortcuts and AppIntents
// ride on top of.

#if DEBUG
@MainActor
enum URLSchemeDebugHandler {
    private static let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                       category: "URLScheme.Debug")

    /// Returns `true` if the URL was a `debug/*` action and was handled
    /// (regardless of success). Returns `false` if the URL isn't a debug
    /// endpoint, so the regular handler can continue.
    static func tryHandle(action: String, params: [String: String], store: ThermalStore) -> Bool {
        // Accept both `host=debug path=/<action>` and `host=debug/<action>` forms
        // depending on how the URL was formatted. Caller is `URLSchemeHandler.handle`
        // which already normalized `action` to include any subpath after `airassist://`.
        guard action.hasPrefix("debug/") || action == "debug" else { return false }
        let sub = action == "debug"
            ? (params["action"] ?? "")
            : String(action.dropFirst("debug/".count))

        logger.info("debug action: \(sub, privacy: .public)")

        switch sub {
        case "ping":
            handlePing(params: params)
        case "export-state":
            handleExportState(params: params, store: store)
        case "stay-awake":
            handleStayAwake(params: params, store: store)
        case "seed-rule":
            handleSeedRule(params: params, store: store)
        case "clear-rules":
            handleClearRules(store: store)
        case "open-dashboard":
            handleOpenDashboard(store: store)
        case "open-preferences":
            handleOpenPreferences(store: store)
        default:
            logger.warning("unknown debug action: \(sub, privacy: .public)")
        }
        return true
    }

    // MARK: - Endpoints

    private static func handlePing(params: [String: String]) {
        guard let path = params["to"] else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        try? "pong\n\(ts)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func handleExportState(params: [String: String], store: ThermalStore) {
        guard let path = params["to"] else {
            logger.warning("export-state missing `to`")
            return
        }
        let throttled = store.processThrottler.throttleDetail.map { entry -> [String: Any] in
            [
                "pid":  Int(entry.pid),
                "name": entry.name,
                "sources": entry.sources.map { key, value -> [String: Any] in
                    ["source": String(describing: key), "duty": value]
                },
            ]
        }
        let rulesCfg = store.throttleRules
        let rules = rulesCfg.rules.map { r -> [String: Any] in
            [
                "id":          r.id,
                "displayName": r.displayName,
                "duty":        r.duty,
                "enabled":     r.isEnabled,
            ]
        }
        let state: [String: Any] = [
            "timestamp":         ISO8601DateFormatter().string(from: Date()),
            "paused":            store.isPauseActive,
            "pausedUntil":       store.pausedUntil.map { ISO8601DateFormatter().string(from: $0) } as Any,
            "throttledProcesses": throttled,
            "rulesEngineEnabled": rulesCfg.enabled,
            "rules":             rules,
            "stayAwakeMode":     stayAwakeTag(store.stayAwake.currentMode),
            // Use NSNull for the "no timer" case — JSONSerialization balks
            // at bare Swift Optionals even cast to Any.
            "stayAwakeDisplayTimerRemaining":
                (store.stayAwake.displayTimerRemaining as Any?) ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func handleStayAwake(params: [String: String], store: ThermalStore) {
        let mode: StayAwakeService.Mode
        switch (params["mode"] ?? "").lowercased() {
        case "off":                mode = .off
        case "system":             mode = .system
        case "display":            mode = .display
        case "displaythensystem":  mode = .displayThenSystem(minutes: 1)
        default:
            logger.warning("stay-awake: invalid mode")
            return
        }
        store.setStayAwakeMode(mode)
    }

    private static func handleSeedRule(params: [String: String], store: ThermalStore) {
        guard let bundle = params["bundle"], !bundle.isEmpty,
              let dutyStr = params["duty"],
              let duty = URLSchemeHandler.parseDuty(dutyStr)
        else {
            logger.warning("seed-rule: missing bundle or duty")
            return
        }
        let enabled = (params["enabled"] ?? "true").lowercased() != "false"
        let displayName = params["name"] ?? bundle
        let keyType = (params["keytype"] ?? "bundle").lowercased()

        // Upsert the rule manually (no RunningProcess handy). The rule ID
        // convention mirrors `ThrottleRule.key(for:)` — bundle key for apps
        // with Info.plist, name key for raw executables.
        var cfg = store.throttleRules
        let id = keyType == "name"
            ? ThrottleRule.nameKey(bundle)
            : ThrottleRule.bundleKey(bundle)
        if let idx = cfg.rules.firstIndex(where: { $0.id == id }) {
            cfg.rules[idx].duty = duty
            cfg.rules[idx].isEnabled = enabled
            cfg.rules[idx].displayName = displayName
        } else {
            cfg.rules.append(ThrottleRule(
                id: id,
                displayName: displayName,
                duty: duty,
                isEnabled: enabled
            ))
        }
        cfg.enabled = true
        store.throttleRules = cfg
    }

    private static func handleClearRules(store: ThermalStore) {
        var cfg = store.throttleRules
        cfg.rules.removeAll()
        cfg.enabled = false
        store.throttleRules = cfg
    }

    private static func handleOpenDashboard(store: ThermalStore) {
        // Bring the app to the foreground so XCUITest can see the window —
        // LSUIElement apps default to accessory mode, and XCUITest expects
        // a regular-activation app for window enumeration.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DashboardWindowController.shared(store: store).show()
    }

    private static func handleOpenPreferences(store: ThermalStore) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        PreferencesWindowController.shared(store: store).show()
    }

    // MARK: - Helpers

    private static func stayAwakeTag(_ mode: StayAwakeService.Mode) -> String {
        switch mode {
        case .off:                       return "off"
        case .system:                    return "system"
        case .display:                   return "display"
        case .displayThenSystem:         return "displayThenSystem"
        }
    }
}
#endif
