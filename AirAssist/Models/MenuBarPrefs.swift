import Foundation

// MARK: - Slot model (two-level: category + value stored separately in UserDefaults)
//
// category key → "none" | "highest" | "average" | "individual"
// value key    → "overall" | "all" | SensorCategory.rawValue | sensor.id

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

// MARK: - Layout

enum MenuBarLayout: String, CaseIterable {
    case single     = "single"
    case sideBySide = "sideBySide"
    case stacked    = "stacked"

    var label: String {
        switch self {
        case .single:     return "Single"
        case .sideBySide: return "Side by Side"
        case .stacked:    return "Stacked"
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
    let value: Double?
    /// The category the displayed value came from. nil for "average"
    /// (multiple categories combined) and for "none"/empty slots.
    let sourceCategory: SensorCategory?
    /// 0…1 distance toward the slot's *hot* threshold, clamped. Used by
    /// the headroom strip. nil if no threshold context exists (e.g.
    /// average-of-everything has no single category to threshold against).
    let headroom: Double?
    /// Most recent samples (oldest→newest). May be empty.
    let history: [Double]

    /// Sentinel for "slot resolves to nothing" — used when a slot is
    /// configured to .none, the chosen sensor disappeared, or no
    /// readings have come in yet.
    static let empty = MenuBarSlotState(
        value: nil, sourceCategory: nil, headroom: nil, history: []
    )
}

/// Single-character abbreviations used by the source badge in the menu
/// bar. Kept here (not buried in the renderer) so `MenuBarSourceBadge`
/// is the single source of truth — the popover header and the
/// VoiceOver string both read from `displayName(for:)` and
/// `accessibilityName(for:)` respectively, and they have to agree with
/// what the user sees on the bar.
///
/// Choices:
///   - CPU → C, GPU → G — obvious
///   - SoC → S — natural; "system on chip"
///   - Storage → D ("disk") — avoids the SoC/Storage S-collision
///   - Battery → B
///   - Other → · (middle dot) — explicitly "miscellaneous", not a letter
enum MenuBarSourceBadge {
    static func character(for category: SensorCategory) -> String {
        switch category {
        case .cpu:     return "C"
        case .gpu:     return "G"
        case .soc:     return "S"
        case .battery: return "B"
        case .storage: return "D"
        case .other:   return "·"
        }
    }

    /// Long form for VoiceOver — "hottest is CPU, 84 degrees" reads
    /// better than "hottest is C, 84 degrees".
    static func accessibilityName(for category: SensorCategory) -> String {
        switch category {
        case .cpu:     return "CPU"
        case .gpu:     return "GPU"
        case .soc:     return "system on chip"
        case .battery: return "battery"
        case .storage: return "storage"
        case .other:   return "other"
        }
    }
}

// MARK: - Trend

/// Slope of the slot's recent history, expressed as a tri-state suitable
/// for a single-glyph hint in the menu bar. The value itself is what the
/// user reads first; the arrow answers "is this still going up, or did
/// it just spike and recover?" without forcing them to open the popover.
enum MenuBarTrend: String, Sendable, Equatable {
    case rising
    case falling
    case flat
}

enum MenuBarTrendCompute {
    /// Threshold (°C, since history is always stored in Celsius) below
    /// which we report `.flat`. Calibrated so a sensor jittering ±0.3°C
    /// between samples doesn't flicker the glyph — the eye is much more
    /// sensitive to glyph flips than to a degree of variation, so this
    /// errs on the side of stability over freshness.
    static let flatBandC: Double = 0.4

    /// Minimum history length to make a slope claim. Below this, return
    /// nil so the renderer hides the glyph rather than guessing from
    /// two samples.
    static let minSamples: Int = 4

    /// Compare the mean of the latest third of `history` against the
    /// mean of the earliest third — gives a smoothed slope sign without
    /// needing real linear regression. Middle samples are ignored on
    /// purpose: they make the comparison less sensitive to a single
    /// outlier in the middle of the window.
    static func compute(_ history: [Double],
                        flatBandC: Double = MenuBarTrendCompute.flatBandC) -> MenuBarTrend? {
        guard history.count >= minSamples else { return nil }
        let third = max(2, history.count / 3)
        let earlySlice = history.prefix(third)
        let lateSlice  = history.suffix(third)
        let earlyMean = earlySlice.reduce(0, +) / Double(earlySlice.count)
        let lateMean  = lateSlice.reduce(0, +)  / Double(lateSlice.count)
        let delta = lateMean - earlyMean
        if delta >  flatBandC { return .rising }
        if delta < -flatBandC { return .falling }
        return .flat
    }

    /// Single glyph for the bar. Up/down arrows are the obvious read,
    /// and an en-dash for flat is calmer than a horizontal bar. Returns
    /// nil for the .flat case when we want to suppress the glyph in
    /// quiet states (caller decides).
    static func glyph(for trend: MenuBarTrend) -> String {
        switch trend {
        case .rising:  return "↑"
        case .falling: return "↓"
        case .flat:    return "·"
        }
    }
}
