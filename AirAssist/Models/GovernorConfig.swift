import Foundation

/// One-click setups for users who don't want to tune individual numbers.
/// Each preset sets all governor fields except `mode`, which is preserved
/// so applying a preset never silently turns the governor on or off.
enum GovernorPreset: String, CaseIterable, Identifiable {
    case gentle, balanced, aggressive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle:     return "Gentle"
        case .balanced:   return "Balanced"
        case .aggressive: return "Aggressive"
        }
    }

    var tagline: String {
        switch self {
        case .gentle:     return "Only step in when things get really hot."
        case .balanced:   return "Sensible defaults — recommended."
        case .aggressive: return "Keep the Mac cool and quiet, even under load."
        }
    }

    /// Apply this preset's numbers to a config, preserving mode.
    func applied(to config: GovernorConfig) -> GovernorConfig {
        var c = config
        switch self {
        case .gentle:
            c.maxTempC             = 93
            c.tempHysteresisC      = 8
            c.maxCPUPercent        = 600
            c.cpuHysteresisPercent = 100
            c.maxTargets           = 3
            c.minCPUForTargeting   = 25
        case .balanced:
            c.maxTempC             = 85
            c.tempHysteresisC      = 5
            c.maxCPUPercent        = 400
            c.cpuHysteresisPercent = 50
            c.maxTargets           = 4
            c.minCPUForTargeting   = 15
        case .aggressive:
            c.maxTempC             = 75
            c.tempHysteresisC      = 3
            c.maxCPUPercent        = 250
            c.cpuHysteresisPercent = 30
            c.maxTargets           = 6
            c.minCPUForTargeting   = 10
        }
        return c
    }
}

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
    /// Default 85°C leaves headroom below Apple Silicon's own thermal
    /// management (which begins in the mid-90s on die sensors). UI
    /// allows up to 100°C; anything higher is dangerous territory
    /// already being governed by macOS itself.
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
        sanitize(&cfg)
        return cfg
    }

    /// Defensive clamps applied on every load. A corrupted or hand-edited
    /// plist must never be able to push the governor into dangerous or
    /// nonsense territory — clamp to the same ranges the UI enforces.
    private static func sanitize(_ cfg: inout GovernorConfig) {
        // Temperature ceiling: 40–100°C. Above 100 overlaps with Apple's own
        // kernel/SMC thermal management; below 40 is unreachable in practice.
        if cfg.maxTempC < 40  { cfg.maxTempC = 40 }
        if cfg.maxTempC > 100 { cfg.maxTempC = 100 }
        // CPU cap: 50 (half a core) – 1600 (16 cores). Keeps the slider sane
        // on both low and high end hardware.
        if cfg.maxCPUPercent < 50   { cfg.maxCPUPercent = 50 }
        if cfg.maxCPUPercent > 1600 { cfg.maxCPUPercent = 1600 }
        // Hysteresis: must be positive and smaller than the cap itself.
        if cfg.tempHysteresisC < 1 { cfg.tempHysteresisC = 1 }
        if cfg.tempHysteresisC > 30 { cfg.tempHysteresisC = 30 }
        if cfg.cpuHysteresisPercent < 5   { cfg.cpuHysteresisPercent = 5 }
        if cfg.cpuHysteresisPercent > 400 { cfg.cpuHysteresisPercent = 400 }
        // Target count: 1–10. Zero would break the engine; >10 would starve
        // the system.
        if cfg.maxTargets < 1  { cfg.maxTargets = 1 }
        if cfg.maxTargets > 10 { cfg.maxTargets = 10 }
        // Targeting threshold: 5%–100% of a core.
        if cfg.minCPUForTargeting < 5   { cfg.minCPUForTargeting = 5 }
        if cfg.minCPUForTargeting > 100 { cfg.minCPUForTargeting = 100 }
    }

    static func save(_ cfg: GovernorConfig) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
