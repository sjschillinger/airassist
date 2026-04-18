import Foundation

/// Per-app throttling rule.
/// Keyed primarily by bundle identifier if we have it, otherwise by
/// executable name. Either key is stable across launches.
struct ThrottleRule: Codable, Identifiable, Hashable {
    /// Either `bundleID:com.foo.bar` or `name:SomeExecutable`.
    var id: String
    var displayName: String
    /// Target CPU availability as a fraction [0.05, 1.0].
    /// 1.0 = no throttling. 0.5 = ~50% of normal CPU consumption.
    /// 0.05 = nearly paused.
    var duty: Double
    /// If false the rule is ignored (soft-disable without deletion).
    var isEnabled: Bool = true

    static func bundleKey(_ bundleID: String) -> String { "bundleID:\(bundleID)" }
    static func nameKey(_ name: String)         -> String { "name:\(name)" }

    /// Build an appropriate key for a given running process.
    static func key(for process: RunningProcess) -> String {
        if let b = process.bundleID { return bundleKey(b) }
        return nameKey(process.name)
    }
}

/// Aggregate configuration persisted to UserDefaults as JSON.
struct ThrottleRulesConfig: Codable {
    /// Whether the per-app rule engine is globally on.
    var enabled: Bool = false
    var rules: [ThrottleRule] = []

    /// Lookup: does a given process match a rule?
    func rule(for process: RunningProcess) -> ThrottleRule? {
        let key = ThrottleRule.key(for: process)
        return rules.first { $0.id == key && $0.isEnabled }
    }
}

/// UserDefaults persistence for per-app throttle rules.
enum ThrottleRulesPersistence {
    private static let key = "throttleRules.v1"

    static func load() -> ThrottleRulesConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              var cfg  = try? JSONDecoder().decode(ThrottleRulesConfig.self, from: data)
        else { return ThrottleRulesConfig() }
        // Defensive: clamp duty for every rule to the throttler's accepted
        // range so a corrupted plist can't produce duty=0 (hard pause) or
        // duty>1 (meaningless but would bypass the release path).
        for i in cfg.rules.indices {
            if cfg.rules[i].duty < ProcessThrottler.minDuty {
                cfg.rules[i].duty = ProcessThrottler.minDuty
            }
            if cfg.rules[i].duty > ProcessThrottler.maxDuty {
                cfg.rules[i].duty = ProcessThrottler.maxDuty
            }
        }
        return cfg
    }

    static func save(_ cfg: ThrottleRulesConfig) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
