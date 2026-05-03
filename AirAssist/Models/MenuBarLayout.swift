import Foundation

/// Top-level menu-bar layout: how many slots, side-by-side or stacked.
/// Persisted as `menuBarLayout` in UserDefaults.
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

/// Single-character abbreviations used by the source badge in the menu
/// bar. Kept here (not buried in the renderer) so `MenuBarSourceBadge`
/// is the single source of truth — the popover header and the
/// VoiceOver string both read from `character(for:)` and
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
