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
