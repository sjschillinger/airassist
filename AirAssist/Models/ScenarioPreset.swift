import Foundation

/// One-click "scenario" presets that bundle a governor configuration with
/// a stay-awake mode and on-battery gating. Higher-level than
/// `GovernorPreset` (which only tunes governor numbers) — these answer
/// "what am I about to do with this Mac" rather than "how aggressive
/// should the governor be."
///
/// Applying a scenario is reversible: each one writes a complete set of
/// values, so re-selecting another scenario fully overrides the previous
/// state. The user's per-app rules are deliberately untouched — those
/// represent persistent intent that scenarios shouldn't clobber.
enum ScenarioPreset: String, CaseIterable, Identifiable {
    case presenting
    case quiet
    case performance
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .presenting:  return String(localized: "Presenting")
        case .quiet:       return String(localized: "Lap / Cool")
        case .performance: return String(localized: "Performance")
        case .auto:        return String(localized: "Auto (default)")
        }
    }

    var sfSymbol: String {
        switch self {
        case .presenting:  return "person.wave.2"
        // Snowflake-on-thermometer reads as "keep this thing cool" at a
        // glance — neutral on whether the cooling comes from fans or
        // just from running less hot.
        case .quiet:       return "thermometer.snowflake"
        case .performance: return "bolt.fill"
        case .auto:        return "wand.and.stars"
        }
    }

    var tagline: String {
        switch self {
        case .presenting:  return String(localized: "Governor off, display awake. No surprise pauses during a demo.")
        case .quiet:       return String(localized: "Holds the chassis cool to the touch by capping sustained heat. Brief bursts pass through. Quieter on Macs with fans.")
        case .performance: return String(localized: "Gentle governor only — high heat ceiling, display awake. Get out of the workload's way.")
        case .auto:        return String(localized: "Balanced caps, on-battery only. Sensible everyday default.")
        }
    }
}
