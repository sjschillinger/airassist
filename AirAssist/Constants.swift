import Foundation

enum AppStrings {
    static let appName = "Air Assist"
    static let bundleID = "com.airAssist.app"

    enum MenuBar {
        static let defaultIcon = "thermometer.medium"
        static let coolIcon = "thermometer.low"
        static let warmIcon = "thermometer.medium"
        static let hotIcon = "thermometer.high"
        static let dashboard = "Dashboard"
        static let preferences = "Preferences…"
        static let quit = "Quit Air Assist"
    }

    enum Dashboard {
        static let title = "Air Assist — Dashboard"
        static let sortBy = "Sort by"
        static let celsius = "°C"
        static let fahrenheit = "°F"
    }

    enum Preferences {
        static let title = "Air Assist — Preferences"
        static let general = "General"
        static let menuBar = "Menu Bar"
        static let sensors = "Sensors"
        static let throttling = "Throttling"
        static let launchAtLogin = "Launch at login"
        static let showDockIcon = "Show dock icon"
        static let updateInterval = "Update interval"
    }

    enum Errors {
        static let sensorReadFailed = "Sensor read failed"
        static let ioKitUnavailable = "IOKit unavailable"
    }
}
