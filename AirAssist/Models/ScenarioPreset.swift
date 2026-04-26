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
        case .presenting:  return "Presenting"
        case .quiet:       return "Quiet"
        case .performance: return "Performance"
        case .auto:        return "Auto (default)"
        }
    }

    var sfSymbol: String {
        switch self {
        case .presenting:  return "person.wave.2"
        case .quiet:       return "wind"
        case .performance: return "bolt.fill"
        case .auto:        return "wand.and.stars"
        }
    }

    var tagline: String {
        switch self {
        case .presenting:  return "Governor off, display awake. No surprise pauses during a demo."
        case .quiet:       return "Aggressive caps, runs on battery and AC. Library / café mode."
        case .performance: return "Gentle governor only — high heat ceiling, display awake. Get out of the workload's way."
        case .auto:        return "Balanced caps, on-battery only. Sensible everyday default."
        }
    }
}
