import Foundation

/// Which system-wide cap modes are active. Freely combinable.
enum GovernorMode: String, Codable, CaseIterable {
    case off         // governor does nothing
    case temperature // enforce maxTempC only
    case cpu         // enforce maxCPUPercent only
    case both        // enforce whichever is breached

    var label: String {
        switch self {
        case .off:         return "Off"
        case .temperature: return "Temperature cap"
        case .cpu:         return "CPU-usage cap"
        case .both:        return "Temperature & CPU caps"
        }
    }
}

/// System-wide throttling caps.
struct GovernorConfig: Codable {
    var mode: GovernorMode = .off
    /// Upper bound for any enabled temperature sensor, °C.
    /// Default 85°C leaves headroom below Apple's own thermal management
    /// (which begins throttling around 95°C on Apple Silicon die sensors),
    /// so our governor intervenes first.
    var maxTempC: Double = 85
    /// Upper bound for total CPU% across all user processes.
    /// 100 = one whole core. 400 = four cores on an M1/M2/M3.
    var maxCPUPercent: Double = 300
    /// Hysteresis in °C before releasing temperature cap throttle.
    var tempHysteresisC: Double = 5
    /// Hysteresis in CPU% before releasing cpu cap throttle.
    var cpuHysteresisPercent: Double = 50
    /// Maximum number of top-CPU processes to simultaneously throttle
    /// when enforcing a cap (keeps system responsive).
    var maxTargets: Int = 4
    /// Minimum CPU% a process must have before the governor will
    /// consider it for throttling (avoids noise).
    var minCPUForTargeting: Double = 15

    /// Quick flags
    var tempEnabled: Bool { mode == .temperature || mode == .both }
    var cpuEnabled:  Bool { mode == .cpu         || mode == .both }
    var isOff:       Bool { mode == .off }
}

enum GovernorConfigPersistence {
    private static let key = "governorConfig.v1"

    static func load() -> GovernorConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              var cfg  = try? JSONDecoder().decode(GovernorConfig.self, from: data)
        else { return GovernorConfig() }
        // Migration: old builds allowed temps up to 110°C, but the OS
        // already throttles by then. Clamp so the UI slider matches.
        if cfg.maxTempC > 95 { cfg.maxTempC = 95 }
        return cfg
    }

    static func save(_ cfg: GovernorConfig) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
