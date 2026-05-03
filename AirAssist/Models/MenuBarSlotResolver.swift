import Foundation

/// Pure routing logic for the menu bar's slot system. Given a slot
/// configuration (metric + sub-config) plus the live data needed to
/// resolve it, returns a fully-baked `MenuBarSlotState` the renderer
/// can paint without further round-tripping.
///
/// Extracted from `ThermalStore` in v0.14.x post-release cleanup.
/// The logic is purely functional — no instance state, no
/// `@MainActor`, no `@Observable` — so it tests as a value type and
/// future metrics (memory pressure, battery %, fan RPM) drop in by
/// adding a case to the switch on `metric` rather than expanding the
/// store.
///
/// Adding a new metric:
///   1. Add the case to `SlotMetric`.
///   2. Add a private `xyzSlot(...)` helper here that builds the
///      `MenuBarSlotState`.
///   3. Add the case to `resolve(...)`'s switch.
///   4. (If the metric needs new live data) extend `resolve(...)`'s
///      parameter list and update the single ThermalStore call site.
///
/// The temperature path is the most involved (Highest / Average /
/// Individual sub-config + per-category thresholds) and lives in
/// `temperatureSlot(...)` to keep `resolve(...)` itself a clean
/// dispatch.
enum MenuBarSlotResolver {

    /// Hard-coded CPU% thresholds for the `cpuTotal` metric. Picked
    /// from common monitoring-app conventions — 60% sustained =
    /// "noticeable", 85% sustained = "actively under load." Pinned
    /// in tests; change here means changing the test expectation
    /// too. ThresholdSettings is sensor-category-shaped today; if
    /// users want configurable CPU thresholds we'll add a parallel
    /// settings struct rather than overloading this one.
    static let cpuTotalWarmPercent: Double = 60
    static let cpuTotalHotPercent: Double = 85

    /// Top-level entry — resolves a slot config to a renderable
    /// state. Caller passes everything the resolver needs as
    /// parameters; the resolver reaches for nothing on its own.
    ///
    /// `@MainActor` because the temperature path reads `Sensor`
    /// properties (`currentValue`, `history`) which are themselves
    /// main-actor-isolated. The CPU% path doesn't strictly need it
    /// — but having one entry point with consistent isolation is
    /// cleaner than splitting by metric, and every caller is on the
    /// main actor anyway.
    @MainActor
    static func resolve(metric: SlotMetric,
                        category: String,
                        value: String,
                        sensors: [Sensor],
                        thresholds: ThresholdSettings,
                        cpuTotalPercent: Double,
                        cpuTotalHistory: [Double]) -> MenuBarSlotState {
        switch metric {
        case .none:
            return .empty
        case .temperature:
            return temperatureSlot(category: category,
                                   value: value,
                                   sensors: sensors,
                                   thresholds: thresholds)
        case .cpuTotal:
            return cpuTotalSlot(percent: cpuTotalPercent,
                                history: cpuTotalHistory)
        }
    }

    // MARK: - Per-metric builders

    /// Temperature slot — has the full Highest / Average /
    /// Individual sub-config tree. `category` is one of
    /// "highest" | "average" | "individual" (other values fall
    /// through to .empty); `value` is "overall" | "all" |
    /// `SensorCategory.rawValue` | sensor.id, depending on the
    /// category.
    @MainActor
    private static func temperatureSlot(category: String,
                                        value: String,
                                        sensors: [Sensor],
                                        thresholds: ThresholdSettings) -> MenuBarSlotState {
        switch category {
        case "highest":
            // "overall" → winner across all enabled sensors,
            // regardless of category. Source badge follows the
            // winner.
            if value == "overall" {
                if let winner = sensors
                    .filter({ $0.currentValue != nil })
                    .max(by: { ($0.currentValue ?? 0) < ($1.currentValue ?? 0) }) {
                    return MenuBarSlotState(
                        value: winner.currentValue,
                        sourceCategory: winner.category,
                        headroom: headroom(value: winner.currentValue,
                                           category: winner.category,
                                           thresholds: thresholds),
                        history: winner.history
                    )
                }
                return .empty
            }
            // Category-pinned highest — winner *within* that
            // category.
            if let cat = SensorCategory(rawValue: value) {
                if let winner = sensors
                    .filter({ $0.category == cat && $0.currentValue != nil })
                    .max(by: { ($0.currentValue ?? 0) < ($1.currentValue ?? 0) }) {
                    return MenuBarSlotState(
                        value: winner.currentValue,
                        sourceCategory: cat,
                        headroom: headroom(value: winner.currentValue,
                                           category: cat,
                                           thresholds: thresholds),
                        history: winner.history
                    )
                }
                // Category empty — fall back to overall highest so
                // the user isn't staring at a blank slot when their
                // preferred category has no sensors.
                if let winner = sensors
                    .filter({ $0.currentValue != nil })
                    .max(by: { ($0.currentValue ?? 0) < ($1.currentValue ?? 0) }) {
                    return MenuBarSlotState(
                        value: winner.currentValue,
                        sourceCategory: winner.category,
                        headroom: headroom(value: winner.currentValue,
                                           category: winner.category,
                                           thresholds: thresholds),
                        history: winner.history
                    )
                }
            }
            return .empty
        case "average":
            // Average has no single source category, so the badge
            // is suppressed. Trend can still be computed off the
            // value itself — but we'd need a separate buffer for
            // the average, and that's out of scope for now (the
            // trend glyph is most useful on a single-sensor reading
            // anyway). History is intentionally empty here.
            if value == "all" {
                return MenuBarSlotState(
                    value: averageTemp(sensors: sensors),
                    sourceCategory: nil, headroom: nil, history: []
                )
            }
            if let cat = SensorCategory(rawValue: value) {
                let inCat = averageTemp(in: cat, sensors: sensors)
                return MenuBarSlotState(
                    value: inCat ?? averageTemp(sensors: sensors),
                    sourceCategory: cat,
                    headroom: headroom(value: inCat,
                                       category: cat,
                                       thresholds: thresholds),
                    history: []
                )
            }
            return .empty
        case "individual":
            if let s = sensors.first(where: { $0.id == value }) {
                return MenuBarSlotState(
                    value: s.currentValue,
                    sourceCategory: s.category,
                    headroom: headroom(value: s.currentValue,
                                       category: s.category,
                                       thresholds: thresholds),
                    history: s.history
                )
            }
            return .empty
        default:
            return .empty
        }
    }

    /// CPU total slot — single global value, no sub-config. Hard-
    /// coded warm/hot thresholds (60% / 85%); see the constants on
    /// this type for the rationale.
    private static func cpuTotalSlot(percent: Double,
                                     history: [Double]) -> MenuBarSlotState {
        MenuBarSlotState(
            value: percent,
            unit: .percent,
            sourceCategory: nil,
            headroom: headroom(value: percent,
                               warm: cpuTotalWarmPercent,
                               hot:  cpuTotalHotPercent) ?? 0,
            history: history
        )
    }

    // MARK: - Helpers

    /// Linear-interpolate `value` across the warm→hot range, clamped
    /// to 0…1. Returns `nil` if the range is degenerate (warm ≥ hot).
    /// Shared by temperature and CPU% so the headroom math lives in
    /// one place.
    static func headroom(value: Double, warm: Double, hot: Double) -> Double? {
        let span = hot - warm
        guard span > 0 else { return nil }
        let raw = (value - warm) / span
        return min(max(raw, 0), 1)
    }

    /// Distance toward the *hot* threshold for `category`, clamped
    /// 0…1. Returns nil if value or thresholds are missing. Used by
    /// the menu-bar headroom strip — gives the user pre-warm
    /// visibility rather than waiting for the tint to flip.
    private static func headroom(value: Double?,
                                 category: SensorCategory,
                                 thresholds: ThresholdSettings) -> Double? {
        guard let value else { return nil }
        let t = thresholds.thresholds(for: category)
        return headroom(value: value, warm: t.warm, hot: t.hot)
    }

    /// Mean of every enabled sensor's current value. nil when nothing
    /// is reading.
    @MainActor
    private static func averageTemp(sensors: [Sensor]) -> Double? {
        let vals = sensors.compactMap(\.currentValue)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    /// Mean within a category. nil if no enabled sensors are in this
    /// category.
    @MainActor
    private static func averageTemp(in category: SensorCategory,
                                    sensors: [Sensor]) -> Double? {
        let vals = sensors.filter { $0.category == category }.compactMap(\.currentValue)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }
}
