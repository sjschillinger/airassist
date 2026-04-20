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
    /// Optional time-window restriction. If nil the rule is active
    /// whenever enabled; if set the engine only applies the rule during
    /// the specified window/days. See #60.
    var schedule: ThrottleSchedule? = nil

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

    /// Lookup: does a given process match a rule? Applies schedule gating
    /// (#60) — an enabled rule outside its active window is treated as
    /// not matching, same as `isEnabled = false`.
    func rule(for process: RunningProcess, now: Date = Date()) -> ThrottleRule? {
        let key = ThrottleRule.key(for: process)
        return rules.first {
            $0.id == key
            && $0.isEnabled
            && ($0.schedule?.isActive(at: now) ?? true)
        }
    }
}

/// Optional time-window on a per-app rule. "Throttle Slack 9am–6pm
/// Mon–Fri" etc. An absent `schedule` means always-on.
///
/// Semantics:
///   * Both `startMinute` and `endMinute` are minutes-since-midnight
///     in the user's local calendar (0…1439).
///   * If `endMinute > startMinute`: active `[start, end)` on selected days.
///   * If `endMinute <= startMinute`: window wraps past midnight —
///     active from `start` on a selected day through `end` the next day.
///     This is the "overnight" case (e.g. 22:00 → 06:00).
///   * `days` is the set of weekdays the *start* of the window falls on,
///     not every minute the window is open. A 22:00→06:00 Friday window
///     means Friday 22:00 → Saturday 06:00. Users model weekly rhythms
///     by the starting day, which matches how we talk about nights.
struct ThrottleSchedule: Codable, Hashable {
    /// 0 = Sunday, 1 = Monday, … 6 = Saturday (matching `Calendar.component(.weekday)`
    /// minus 1, the zero-indexed weekday).
    var days: Set<Int>
    /// Minutes since midnight for window start, inclusive. 0…1439.
    var startMinute: Int
    /// Minutes since midnight for window end, exclusive. 0…1439.
    var endMinute: Int

    static func weekdays() -> Set<Int> { [1, 2, 3, 4, 5] }
    static func weekends() -> Set<Int> { [0, 6] }
    static func everyDay() -> Set<Int> { [0, 1, 2, 3, 4, 5, 6] }

    /// Is the window currently active? See the struct comment for the
    /// overnight-wrap rule.
    func isActive(at date: Date) -> Bool {
        let cal = Calendar.current
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute
        else { return false }
        let today = (weekday - 1 + 7) % 7      // 0..6 Sun..Sat
        let yesterday = (today - 1 + 7) % 7
        let nowMin = hour * 60 + minute

        if endMinute > startMinute {
            // Non-wrapping: today must be a selected day, and now must
            // fall inside the window.
            return days.contains(today) && (startMinute..<endMinute).contains(nowMin)
        } else {
            // Wrapping (overnight). Active if:
            //   • today is a selected day and now >= startMinute, OR
            //   • yesterday is a selected day and now <  endMinute.
            if days.contains(today) && nowMin >= startMinute { return true }
            if days.contains(yesterday) && nowMin < endMinute { return true }
            return false
        }
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
