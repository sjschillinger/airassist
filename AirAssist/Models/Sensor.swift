import Foundation

enum SensorCategory: String, Codable, CaseIterable {
    // Display / grouping order is driven by `allCases` — CPU and GPU lead
    // because they're what most users care about day-to-day; SoC, battery,
    // storage, and the catch-all "other" follow.
    case cpu     = "CPU"
    case gpu     = "GPU"
    case soc     = "SoC"
    case battery = "Battery"
    case storage = "Storage"
    case other   = "Other"
}

enum ThresholdState {
    case cool, warm, hot, unknown
}

/// How the popover's sensor list is rendered.
/// - `detailed`: one row per sensor, grouped by category (the default;
///   matches what long-time users expect).
/// - `summary`: one row per category showing High / Avg / Low across the
///   sensors in that category. Much shorter on Macs with lots of dies.
enum SensorDisplayMode: String, CaseIterable {
    case detailed = "detailed"
    case summary  = "summary"

    var label: String {
        switch self {
        case .detailed: return "Detailed"
        case .summary:  return "Summary"
        }
    }
}

@Observable
@MainActor
final class Sensor: Identifiable {
    /// Number of historical samples kept for the sparkline (~60s at 1Hz).
    static let historyCapacity: Int = 60

    let id: String            // stable registry-ID hex string from IOKit
    let rawName: String       // original IOKit product string
    let displayName: String   // human-readable mapped name
    let category: SensorCategory
    var currentValue: Double?
    var isEnabled: Bool = true
    /// Rolling temperature history, oldest → newest. Appended by the
    /// SensorService each poll. Used by the sparkline on sensor cards.
    var history: [Double] = []

    init(id: String, rawName: String, category: SensorCategory) {
        self.id          = id
        self.rawName     = rawName
        self.displayName = SensorCategorizer.displayName(for: rawName)
        self.category    = category
    }

    /// Append a reading and trim to `historyCapacity`.
    func pushHistory(_ value: Double) {
        history.append(value)
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
        }
    }

    func thresholdState(using thresholds: ThresholdSettings) -> ThresholdState {
        guard let value = currentValue else { return .unknown }
        let t = thresholds.thresholds(for: category)
        if value >= t.hot  { return .hot }
        if value >= t.warm { return .warm }
        return .cool
    }
}

struct CategoryThresholds: Codable {
    var warm: Double
    var hot: Double
}

/// One-click threshold profiles (#58). The numbers that drive
/// "when does a sensor turn yellow/red in the menu" for users who
/// don't want to tune six per-category pairs by hand.
///
/// Philosophy: three points on the same curve, not three different
/// curves. Conservative lifts every warn/hot by roughly +5/+5 °C over
/// Balanced; Aggressive lowers them by the same. The relative ordering
/// across categories (battery hot < storage hot < GPU < CPU < SoC)
/// stays intact — only the absolute bar shifts. This keeps the user
/// mental model simple: "I want to be alerted earlier / later."
enum ThresholdPreset: String, CaseIterable, Identifiable {
    case conservative, balanced, aggressive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced:     return "Balanced"
        case .aggressive:   return "Aggressive"
        }
    }

    var tagline: String {
        switch self {
        case .conservative: return "Warn later — for users who run hot workloads as normal."
        case .balanced:     return "Sensible defaults — recommended."
        case .aggressive:   return "Warn earlier — for users who want to stay cool."
        }
    }

    /// Apply to a fresh ThresholdSettings. See note above about the
    /// uniform-shift shape of the three presets.
    var settings: ThresholdSettings {
        switch self {
        case .conservative:
            return ThresholdSettings(
                cpu:     CategoryThresholds(warm: 65, hot: 90),
                gpu:     CategoryThresholds(warm: 60, hot: 85),
                soc:     CategoryThresholds(warm: 70, hot: 95),
                battery: CategoryThresholds(warm: 38, hot: 43),
                storage: CategoryThresholds(warm: 50, hot: 65),
                other:   CategoryThresholds(warm: 65, hot: 85)
            )
        case .balanced:
            return ThresholdSettings() // the designed defaults
        case .aggressive:
            return ThresholdSettings(
                cpu:     CategoryThresholds(warm: 55, hot: 80),
                gpu:     CategoryThresholds(warm: 50, hot: 75),
                soc:     CategoryThresholds(warm: 60, hot: 85),
                battery: CategoryThresholds(warm: 32, hot: 38),
                storage: CategoryThresholds(warm: 40, hot: 55),
                other:   CategoryThresholds(warm: 55, hot: 75)
            )
        }
    }
}

struct ThresholdSettings: Codable {
    var cpu     = CategoryThresholds(warm: 60, hot: 85)
    var gpu     = CategoryThresholds(warm: 55, hot: 80)
    var soc     = CategoryThresholds(warm: 65, hot: 90)
    var battery = CategoryThresholds(warm: 35, hot: 40)
    var storage = CategoryThresholds(warm: 45, hot: 60)
    var other   = CategoryThresholds(warm: 60, hot: 80)

    func thresholds(for category: SensorCategory) -> CategoryThresholds {
        switch category {
        case .cpu:     return cpu
        case .gpu:     return gpu
        case .soc:     return soc
        case .battery: return battery
        case .storage: return storage
        case .other:   return other
        }
    }
}
