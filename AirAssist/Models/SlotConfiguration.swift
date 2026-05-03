import Foundation

// MARK: - Slot model
//
// Each menu-bar slot is configured by three keys in UserDefaults:
//
//   slot{1,2}Metric    → SlotMetric.rawValue. New in v0.14 — defaults
//                        to "temperature" so users upgrading from
//                        v0.13 see no change.
//   slot{1,2}Category  → SlotCategory.rawValue ("highest" | "average" |
//                        "individual" | "none"). Only meaningful when
//                        metric == .temperature.
//   slot{1,2}Value     → "overall" | "all" | SensorCategory.rawValue |
//                        sensor.id. Only meaningful when
//                        metric == .temperature.
//
// For non-temperature metrics (`.cpuTotal`, future: memory, battery)
// the Category and Value keys are unused — the metric itself is
// fully specified.

/// What a single menu-bar slot is showing. Temperature stays the
/// flagship case (with its own category/value sub-config below);
/// other metrics are first-class siblings.
enum SlotMetric: String, CaseIterable, Identifiable {
    /// Temperature reading from one or more sensors. Sub-config in
    /// `SlotCategory` + the value key tells us which sensor(s).
    case temperature

    /// Total system CPU usage as a percentage. 100% = every core
    /// fully pegged (so an 8-core M2 reads 0–800%). Same convention
    /// as `top` and the per-process `cpuPercent` field.
    case cpuTotal

    /// Slot is off — show nothing in this position.
    case none

    var id: String { rawValue }

    /// User-facing label in the Preferences picker.
    var label: String {
        switch self {
        case .temperature: return "Temperature"
        case .cpuTotal:    return "CPU usage"
        case .none:        return "None"
        }
    }

    /// Whether this metric has additional sub-configuration via the
    /// existing `SlotCategory` + value keys. Only temperature does;
    /// the rest are fully specified by the metric alone.
    var hasSubConfig: Bool {
        self == .temperature
    }
}

enum SlotCategory: String, CaseIterable {
    case none       = "none"
    case highest    = "highest"
    case average    = "average"
    case individual = "individual"

    var label: String {
        switch self {
        case .none:       return "None"
        case .highest:    return "Highest"
        case .average:    return "Average"
        case .individual: return "Individual"
        }
    }

    // Default sub-value when category is first selected
    var defaultValue: String {
        switch self {
        case .none:       return ""
        case .highest:    return SensorCategory.cpu.rawValue
        case .average:    return SensorCategory.cpu.rawValue
        case .individual: return ""
        }
    }
}

// MARK: - Resolved slot state

/// What ThermalStore.resolveSlot(...) hands back to the menu bar
/// renderer. The renderer can paint a complete slot from this — value,
/// trend, headroom, source badge — without re-querying the store.
///
/// Carrying `sourceCategory` here is what lets the "Highest" mode show a
/// 1-char badge so the user can tell whether the displayed number is
/// CPU, GPU, SoC, etc. Without that, "91°" in highest-overall mode is
/// genuinely ambiguous.
///
/// `history` is the per-slot rolling sample (oldest→newest) used for the
/// trend micro-glyph. For "highest"/"individual" it's the winning
/// sensor's history; for "average" it's the moving average reconstructed
/// from current values seen on each tick.
struct MenuBarSlotState: Sendable, Equatable {
    /// The unit a slot's value is expressed in. Drives formatting in
    /// the menu bar renderer ("84°" vs "84%") and the threshold logic
    /// for the headroom strip / color tint.
    enum Unit: String, Sendable, Equatable {
        /// Degrees, with the user's chosen unit (C/F) applied at
        /// render time. Default for back-compat — every existing
        /// MenuBarSlotState call site uses this.
        case temperature
        /// Percentage 0…N. Used by CPU% and (later) other 0–100-style
        /// metrics. Renderer formats with a `%` suffix; the unit
        /// converter for C/F is bypassed.
        case percent
    }

    let value: Double?
    let unit: Unit
    /// The category the displayed value came from. Only meaningful for
    /// temperature slots (and even then only `.highest` / `.individual`
    /// — average sets this to nil). nil for non-temperature metrics.
    let sourceCategory: SensorCategory?
    /// 0…1 distance toward the slot's *hot* threshold, clamped. Used by
    /// the headroom strip. nil if no threshold context exists (e.g.
    /// average-of-everything has no single category to threshold against).
    let headroom: Double?
    /// Most recent samples (oldest→newest). May be empty.
    let history: [Double]

    /// Custom initializer with `unit` defaulting to `.temperature` —
    /// every pre-v0.14 call site constructed temperature slots, so
    /// they continue to compile without changes. New non-temperature
    /// call sites pass `unit:` explicitly.
    init(value: Double?,
         unit: Unit = .temperature,
         sourceCategory: SensorCategory?,
         headroom: Double?,
         history: [Double]) {
        self.value = value
        self.unit = unit
        self.sourceCategory = sourceCategory
        self.headroom = headroom
        self.history = history
    }

    /// Sentinel for "slot resolves to nothing" — used when a slot is
    /// configured to .none, the chosen sensor disappeared, or no
    /// readings have come in yet.
    static let empty = MenuBarSlotState(
        value: nil, sourceCategory: nil, headroom: nil, history: []
    )
}
