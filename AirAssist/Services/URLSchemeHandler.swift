import Foundation
import AppKit
import os

/// Handles `airassist://` URLs. Surface is intentionally small and stable — it
/// doubles as the input layer for the Shortcuts.app AppIntents, so anything
/// added here becomes an API contract for user automations.
///
/// Supported actions (all return silently on failure to avoid raising modals
/// for deep links):
///
///   airassist://pause[?duration=15m|1h|30s|forever]
///   airassist://resume
///   airassist://throttle?bundle=<id>&duty=<0.05-1.0>[&duration=15m]
///   airassist://release?bundle=<id>
///   airassist://open-dashboard
///   airassist://open-preferences
///
/// Duration format:
///   - `forever`  → until the app quits (nil duration)
///   - `<n>s`     → seconds
///   - `<n>m`     → minutes
///   - `<n>h`     → hours
///   - `<n>`      → seconds (no suffix)
///   - default for throttle: 1 hour. default for pause: forever (no auto-resume).
///
/// Duty format:
///   - fraction  (0.5)  → 50% of normal CPU
///   - percent   (50%)  → also 50%. Trailing "%" accepted for ergonomics.
///   - Clamped to ProcessThrottler.minDuty…maxDuty.
@MainActor
enum URLSchemeHandler {
    static let scheme = "airassist"

    private static let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                       category: "URLScheme")

    /// Entry point called from `AppDelegate.application(_:open:)`.
    static func handle(_ url: URL, store: ThermalStore) {
        guard url.scheme?.lowercased() == scheme else {
            logger.debug("Ignoring URL with wrong scheme: \(url.absoluteString, privacy: .public)")
            return
        }
        let action = normalizeAction(url)
        let params = queryParams(url)

        logger.info("Received airassist:// action=\(action, privacy: .public)")

        #if DEBUG
        // Debug endpoints used by the integration test bundle. Compiled out
        // of Release builds — see URLSchemeHandler+Debug.swift for the
        // handler. Returns early when the URL was a debug action.
        if URLSchemeDebugHandler.tryHandle(action: action, params: params, store: store) {
            return
        }
        #endif

        switch action {
        case "pause":
            let duration = params["duration"].flatMap(parseDuration(_:))
            store.pauseThrottling(for: duration)

        case "resume":
            store.resumeThrottling()

        case "throttle":
            guard let bundle = params["bundle"], !bundle.isEmpty,
                  let dutyStr = params["duty"], let duty = parseDuty(dutyStr)
            else {
                logger.warning("throttle missing/invalid bundle or duty")
                return
            }
            let duration = params["duration"].flatMap(parseDuration(_:)) ?? 60 * 60
            let affected = store.throttleBundle(bundleID: bundle, duty: duty, duration: duration)
            logger.info("throttle bundle=\(bundle, privacy: .public) duty=\(duty) affected=\(affected)")

        case "scenario":
            guard let name = params["name"]?.lowercased(),
                  let preset = ScenarioPreset(rawValue: name)
            else {
                logger.warning("scenario missing/invalid name (expected presenting/quiet/performance/auto)")
                return
            }
            store.applyScenario(preset)
            logger.info("scenario applied=\(name, privacy: .public)")

        case "release":
            guard let bundle = params["bundle"], !bundle.isEmpty else {
                logger.warning("release missing bundle")
                return
            }
            let n = store.releaseBundle(bundleID: bundle)
            logger.info("release bundle=\(bundle, privacy: .public) released=\(n)")

        case "open-dashboard":
            // Window controllers handle their own NSApp.activate; no
            // need to flip activation policy. App stays .accessory.
            DashboardWindowController.shared(store: store).show()

        case "open-preferences":
            PreferencesWindowController.shared(store: store).show()

        default:
            logger.warning("Unknown action: \(action, privacy: .public)")
        }
    }

    // MARK: - Parsing helpers

    /// Normalize an `airassist://` URL down to a single slash-separated
    /// lowercase action. Internal so unit tests can lock in the contract.
    ///
    ///   airassist://pause                → host="pause",  path=""       → "pause"
    ///   airassist:///pause               → host="",       path="/pause" → "pause"
    ///   airassist://debug/ping           → host="debug",  path="/ping"  → "debug/ping"
    ///   airassist://debug/ping?to=/tmp   → host="debug",  path="/ping"  → "debug/ping"
    ///
    /// Before this helper existed we only looked at `host`, so
    /// `airassist://debug/ping` collapsed to `"debug"` and the debug
    /// sub-router fell through with a bogus "unknown debug action: " log
    /// — wedging the integration suite.
    static func normalizeAction(_ url: URL) -> String {
        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let host = url.host, !host.isEmpty {
            return trimmedPath.isEmpty
                ? host.lowercased()
                : "\(host.lowercased())/\(trimmedPath.lowercased())"
        }
        return trimmedPath.lowercased()
    }

    private static func queryParams(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            if let v = item.value { out[item.name.lowercased()] = v }
        }
        return out
    }

    /// Returns nil for `forever` (meaning "until quit"), or a TimeInterval.
    /// Returns nil for parse failures too — caller decides default.
    static func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "forever" || trimmed == "indefinite" { return nil }
        // Split numeric prefix from unit suffix
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value >= 0 else { return nil }
        let suffix = trimmed.dropFirst(digits.count)
        switch suffix {
        case "", "s", "sec", "secs", "seconds": return value
        case "m", "min", "mins", "minutes":     return value * 60
        case "h", "hr", "hrs", "hours":         return value * 60 * 60
        default:                                return nil
        }
    }

    /// Accepts "0.5", "50%", "50" (treated as percent when > 1). Clamps to
    /// the throttler's accepted range. Returns nil for bad input.
    static func parseDuty(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let hadPercent = trimmed.hasSuffix("%")
        let core = hadPercent ? String(trimmed.dropLast()) : trimmed
        guard let raw = Double(core), raw.isFinite, raw >= 0 else { return nil }
        let normalized: Double
        if hadPercent || raw > 1.0 {
            normalized = raw / 100.0
        } else {
            normalized = raw
        }
        return min(max(normalized, ProcessThrottler.minDuty), ProcessThrottler.maxDuty)
    }
}
