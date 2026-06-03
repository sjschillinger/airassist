import Foundation

/// Centralised user-visible strings.
///
/// Each entry routes through `String(localized:)` so Xcode's Swift
/// localization extractor (`SWIFT_EMIT_LOC_STRINGS = YES`) picks them
/// up at build time and merges them into `Localizable.xcstrings`.
/// Constants stay typed as `String` so existing call sites (raw `Text`
/// inits, `os.Logger` formatting, AppleScript, debug logs) keep working
/// without per-site changes.
///
/// `appName` and `bundleID` are deliberately *not* localized — the
/// product name and reverse-DNS identifier are fixed regardless of
/// locale.
enum AppStrings {

    // MARK: - Language

    /// Supported app languages for in-app language switching.
    /// Stored in UserDefaults under `appLanguage`; on change, sets
    /// `AppleLanguages` and the user is prompted to restart.
    enum AppLanguage: String, CaseIterable, Identifiable {
        case english  = "en"
        case chinese  = "zh-Hans"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .english: return "English"
            case .chinese: return "中文"
            }
        }

        /// Set `AppleLanguages` so the next app launch picks up this
        /// language. Does NOT take effect until the process restarts.
        func activate() {
            UserDefaults.standard.set(rawValue, forKey: "appLanguage")
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }

        /// Read the persisted language preference. If the user has never
        /// explicitly chosen a language (no stored `appLanguage`), respect
        /// the system's preferred languages by scanning
        /// `Locale.preferredLanguages` for the first supported language ID.
        ///
        /// Falls back to `.english` when the system languages list is empty
        /// or contains only unsupported locales.
        static var current: AppLanguage {
            // 1. Explicit user choice takes priority
            if let stored = UserDefaults.standard.string(forKey: "appLanguage"),
               let lang = AppLanguage(rawValue: stored) {
                return lang
            }

            // 2. Otherwise, pick the first system-preferred language that we support
            let supportedIDs = Set(AppLanguage.allCases.map(\.rawValue))
            for preferred in Locale.preferredLanguages {
                // preferred is a full locale identifier like "zh-Hans-CN" or "en-US"
                // We check progressively: full match, language-only match, then just the
                // language code portion.
                let lowered = preferred.lowercased()
                if supportedIDs.contains(lowered) {
                    return AppLanguage(rawValue: lowered)!
                }
                // Prefix match against the supported IDs so the real macOS
                // locale ids resolve: "zh-hans-cn" -> "zh-hans", "en-us" ->
                // "en". (The earlier language-code-only check failed for
                // Chinese because the supported id is "zh-hans", not "zh".)
                if let match = supportedIDs.first(where: { lowered.hasPrefix($0) }) {
                    return AppLanguage(rawValue: match)!
                }
                // e.g., "fr-ca" -> "fr" (no match here; falls through).
                let langPart = String(lowered.prefix(while: { $0 != "-" }))
                if supportedIDs.contains(langPart) {
                    return AppLanguage(rawValue: langPart)!
                }
            }

            // 3. No match — safe fallback
            return .english
        }

        /// Apply on launch so the correct .xcstrings translations load.
        /// Only overrides `AppleLanguages` if the user hasn't set a custom
        /// language via the in-app picker, because that preference must
        /// survive across relaunches.
        static func applyOnLaunch() {
            let preferred = current
            // Only write the system-detected language if no explicit choice exists.
            // This way "activate()" (which writes both keys) continues to work.
            if UserDefaults.standard.string(forKey: "appLanguage") == nil {
                UserDefaults.standard.set([preferred.rawValue], forKey: "AppleLanguages")
            }
        }
    }
    static let appName  = "Air Assist"
    static let bundleID = "com.sjschillinger.airassist"

    enum MenuBar {
        // SF Symbol names — never localized.
        static let defaultIcon = "thermometer.medium"
        static let coolIcon    = "thermometer.low"
        static let warmIcon    = "thermometer.medium"
        static let hotIcon     = "thermometer.high"

        static let dashboard   = String(localized: "Dashboard",
                                        comment: "Menu bar item: opens the Dashboard window")
        static let preferences = String(localized: "Preferences…",
                                        comment: "Menu bar item: opens Preferences")
        static let quit        = String(localized: "Quit Air Assist",
                                        comment: "Menu bar item: quits the app")
    }

    enum Dashboard {
        static let title       = String(localized: "Air Assist — Dashboard",
                                        comment: "Dashboard window title")
        static let sortBy      = String(localized: "Sort by",
                                        comment: "Dashboard: sort menu label")
        // Temperature unit suffixes are conventionally not localized.
        static let celsius     = "°C"
        static let fahrenheit  = "°F"
    }

    enum Preferences {
        static let title           = String(localized: "Air Assist — Preferences",
                                            comment: "Preferences window title")
        static let general         = String(localized: "General",
                                            comment: "Preferences tab: General")
        static let menuBar         = String(localized: "Menu Bar",
                                            comment: "Preferences tab: Menu Bar")
        static let sensors         = String(localized: "Sensors",
                                            comment: "Preferences tab: Sensors")
        static let throttling      = String(localized: "Throttling",
                                            comment: "Preferences tab: Throttling")
        static let launchAtLogin   = String(localized: "Launch at login",
                                            comment: "Preferences toggle")
        static let showDockIcon    = String(localized: "Show dock icon",
                                            comment: "Preferences toggle")
        static let updateInterval  = String(localized: "Update interval",
                                            comment: "Preferences slider label")
    }

    enum Errors {
        static let sensorReadFailed = String(localized: "Sensor read failed",
                                             comment: "Error shown when no sensors return")
        static let ioKitUnavailable = String(localized: "IOKit unavailable",
                                             comment: "Error shown when IOKit can't be reached")
    }
}
