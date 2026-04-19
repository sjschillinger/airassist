import AppIntents
import AppKit
import Foundation

// MARK: - Shortcuts.app integration (#54)
//
// Three actions:
//   • Pause AirAssist (with optional duration)
//   • Resume AirAssist
//   • Throttle Frontmost App (with duty %)
//
// Design decision: every intent dispatches through the `airassist://`
// URL scheme rather than poking `ThermalStore` directly. Reasons:
//   1. There's exactly one code path handling these commands
//      (`URLSchemeHandler`), covered by unit tests. The intents are a
//      tiny wrapper that stringifies params into a URL.
//   2. `LSUIElement = true` makes direct in-process intent handling
//      awkward — without a `openAppWhenRun = true` we can't always
//      reach the running instance. Opening a URL trampolines through
//      LaunchServices, which cold-launches the app if needed, then
//      hands the URL to `application(_:open:)`.
//   3. The URL scheme is a supported public API of the app; Shortcuts
//      just becomes a nicer front-end for it.

@available(macOS 13.0, *)
struct PauseAirAssistIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause AirAssist"
    static let description = IntentDescription(
        "Temporarily release every throttled process. Governor and per-app rules stop firing until resumed or the duration expires."
    )
    /// Opening the app isn't strictly needed (LaunchServices wakes it via
    /// the URL), but leaving `openAppWhenRun = false` keeps Shortcuts from
    /// momentarily focusing a menu-bar-only app.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Duration",
               description: "How long to pause (e.g. 15m, 1h). Leave blank for indefinite.",
               default: nil)
    var duration: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        var url = "airassist://pause"
        if let d = duration, !d.isEmpty {
            url += "?duration=\(d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? d)"
        }
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
        return .result()
    }
}

@available(macOS 13.0, *)
struct ResumeAirAssistIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume AirAssist"
    static let description = IntentDescription(
        "Lift any active pause and let the governor + per-app rules take effect again."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        if let u = URL(string: "airassist://resume") {
            NSWorkspace.shared.open(u)
        }
        return .result()
    }
}

@available(macOS 13.0, *)
struct ThrottleFrontmostAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Throttle Frontmost App"
    static let description = IntentDescription(
        "Apply a CPU duty cap to the currently-frontmost application. Expires automatically after the duration."
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Duty (%)",
               description: "Percent of CPU time the app is allowed — 5 to 100.",
               default: 50,
               inclusiveRange: (5, 100))
    var dutyPercent: Int

    @Parameter(title: "Duration",
               description: "Auto-release after this duration (e.g. 30m, 1h). Default 1h.",
               default: "1h")
    var duration: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Resolve the frontmost app at intent-invocation time.
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return .result(dialog: "No frontmost app bundle available to throttle.")
        }
        let escapedBundle = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
        let duty = max(5, min(100, dutyPercent))
        let escapedDur = duration.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? duration
        let urlStr = "airassist://throttle?bundle=\(escapedBundle)&duty=\(duty)%&duration=\(escapedDur)"
        if let u = URL(string: urlStr) {
            NSWorkspace.shared.open(u)
        }
        let name = app.localizedName ?? bundleID
        return .result(dialog: "Throttling \(name) to \(duty)% for \(duration).")
    }
}

@available(macOS 13.0, *)
struct AirAssistShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseAirAssistIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause throttling in \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeAirAssistIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Unpause \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ThrottleFrontmostAppIntent(),
            phrases: [
                "Throttle frontmost app with \(.applicationName)",
                "Cool down the current app with \(.applicationName)"
            ],
            shortTitle: "Throttle Frontmost",
            systemImageName: "speedometer"
        )
    }
}
