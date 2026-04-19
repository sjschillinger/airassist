import AppKit
import Foundation
import os

/// One-click diagnostic bundle (#46). Collects everything a GitHub-issue
/// triager needs in a single .zip so the user doesn't have to answer ten
/// "what's your macOS version / what thresholds / attach your logs"
/// follow-ups.
///
/// **What goes in the bundle:**
///   - `system.txt` — macOS version, hardware identifier, app version,
///     bundle identifier, current UID.
///   - `config.json` — the user's governor config, threshold settings,
///     throttle rules, menu bar prefs. Anything driven from UserDefaults
///     with an AirAssist-owned key.
///   - `live-state.json` — snapshot of the currently throttled PIDs with
///     their sources and duties, current sensor readings, current pause
///     state. A moment-in-time picture to compare against the reported
///     misbehavior.
///   - `thermal_history.ndjson` (copy) — up to the last 7 days of
///     per-category peak samples from HistoryLogger.
///   - `README.txt` — one-page explainer listing the files and a privacy
///     reminder (no log shipping, no sensor-content upload, this is
///     local-first).
///
/// **Privacy posture:** the bundle is written to a user-chosen
/// location (NSSavePanel) and never sent anywhere by the app. Users can
/// inspect / redact / attach-as-they-see-fit before posting to GitHub.
@MainActor
enum DiagnosticBundle {
    private static let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                       category: "Diagnostics")

    /// Present a save panel, write the bundle, then reveal in Finder on success.
    static func exportInteractively(store: ThermalStore) {
        let panel = NSSavePanel()
        panel.title = "Export Air Assist Diagnostics"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultFilename()
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        let response = panel.runModal()
        guard response == .OK, let destURL = panel.url else { return }

        do {
            try writeBundle(to: destURL, store: store)
            NSWorkspace.shared.activateFileViewerSelecting([destURL])
        } catch {
            logger.error("diagnostic export failed: \(String(describing: error))")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't export diagnostics."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func defaultFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return "airassist-diagnostics-\(df.string(from: Date())).zip"
    }

    // MARK: - Build

    private static func writeBundle(to destURL: URL, store: ThermalStore) throws {
        let fm = FileManager.default
        // Stage into a temp dir, zip, move. Using /usr/bin/zip means no
        // third-party compression dependency; the system ships with it.
        let stage = fm.temporaryDirectory.appendingPathComponent(
            "airassist-diag-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        try writeSystemInfo(to: stage.appendingPathComponent("system.txt"))
        try writeConfig(to: stage.appendingPathComponent("config.json"))
        try writeLiveState(store: store, to: stage.appendingPathComponent("live-state.json"))
        try copyHistoryIfPresent(to: stage.appendingPathComponent("thermal_history.ndjson"))
        try writeReadme(to: stage.appendingPathComponent("README.txt"))

        // Remove any pre-existing file at destination — NSSavePanel already
        // confirmed overwrite with the user, but `/usr/bin/zip` refuses to
        // overwrite silently and we want atomic semantics.
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = stage
        task.arguments = ["-r", "-q", destURL.path, "."]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "DiagnosticBundle", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "zip failed with exit \(task.terminationStatus)"]
            )
        }
    }

    private static func writeSystemInfo(to url: URL) throws {
        let pinfo = ProcessInfo.processInfo
        let ver = pinfo.operatingSystemVersion
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let body = """
        Air Assist — diagnostic bundle (\(Date()))

        App version:   \(appVersion) (\(build))
        Bundle ID:     \(Bundle.main.bundleIdentifier ?? "?")
        macOS version: \(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)
        Host model:    \(hardwareModel())
        User UID:      \(getuid())
        Hostname:      \(pinfo.hostName)
        Physical mem:  \(pinfo.physicalMemory / (1024*1024)) MiB
        Processors:    \(pinfo.processorCount)
        """
        try body.data(using: .utf8)?.write(to: url)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func writeConfig(to url: URL) throws {
        // Whitelist our keys. Don't dump all defaults — that would include
        // framework / system prefs the user hasn't authored.
        let keys = [
            "governorConfig.v1",
            "throttleRules.v1",
            "com.sjschillinger.airassist.thresholds",
            "menuBarPrefs.v1",
            "updateInterval",
            "tempUnit",
            "sensorDisplayMode",
            "sensorList.collapsedCategories",
            "sensorList.expandedCategories",
            BatteryAwareMode.enabledKey,
            BatteryAwareMode.onBatteryPresetKey,
            BatteryAwareMode.onPoweredPresetKey,
            GlobalHotkeyService.enabledDefaultsKey,
            "firstRunDisclosure.seenVersion",
            "onboarding.seenVersion",
        ]
        var out: [String: Any] = [:]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) {
                // JSON-serializable check; fall back to a descriptive string.
                if JSONSerialization.isValidJSONObject([v]) {
                    out[k] = v
                } else if let d = v as? Data,
                          let s = String(data: d, encoding: .utf8) {
                    // Decode our own JSON-in-Data config blobs so they read
                    // human-legibly in the bundle.
                    if let obj = try? JSONSerialization.jsonObject(with: d) {
                        out[k] = obj
                    } else {
                        out[k] = s
                    }
                } else {
                    out[k] = String(describing: v)
                }
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: out,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    private static func writeLiveState(store: ThermalStore, to url: URL) throws {
        let throttled = store.processThrottler.throttleDetail.map { entry -> [String: Any] in
            [
                "pid": Int(entry.pid),
                "name": entry.name,
                "sources": entry.sources.map { key, value -> [String: Any] in
                    ["source": String(describing: key), "duty": value]
                }
            ]
        }
        let sensors: [[String: Any]] = store.enabledSensors.map { s in
            [
                "id": s.id,
                "name": s.displayName,
                "category": s.category.rawValue,
                "temperature": s.currentValue as Any,
            ]
        }
        let state: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "paused": store.isPauseActive,
            "pausedUntil": store.pausedUntil.map { ISO8601DateFormatter().string(from: $0) } as Any,
            "throttledProcesses": throttled,
            "sensors": sensors,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    private static func copyHistoryIfPresent(to dest: URL) throws {
        let src = HistoryReader.fileURL
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try FileManager.default.copyItem(at: src, to: dest)
    }

    private static func writeReadme(to url: URL) throws {
        let body = """
        Air Assist diagnostic bundle
        ============================

        This zip contains:

          system.txt               macOS version + hardware model + app version
          config.json              your current preferences, rules, thresholds
          live-state.json          snapshot of sensors + throttled processes at
                                   the moment of export
          thermal_history.ndjson   per-category peak temperatures over the last
                                   few days (if history has been collected)

        Privacy note. Air Assist never uploads this file. It was written
        locally to the path you chose. Before attaching to a public issue
        tracker, skim it — it should contain no credentials or sensitive
        content, but you're in control of what you share.
        """
        try body.data(using: .utf8)?.write(to: url)
    }
}
