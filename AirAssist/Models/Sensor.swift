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
