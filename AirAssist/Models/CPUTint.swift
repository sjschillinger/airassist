import SwiftUI

/// Color tier for a per-process CPU% reading. Used wherever the app
/// surfaces a process's live CPU usage — popover CPU Activity rows,
/// Throttling-prefs Top Consumers rows, dashboard Top CPU rows — so
/// the same number is the same color everywhere.
///
/// Thresholds are chosen for the per-core convention (`100% = one
/// full core`):
///   - **secondary** (< 25%): below 1/4 of a core; not interesting,
///     keep it visually quiet
///   - **primary** (25%–<75%): in active use but not pegged
///   - **orange** (75%–<150%): pegging one core or close to it; user
///     should know
///   - **red** (≥ 150%): multiple cores burning; this is a hog
///
/// Defined as a `static func` rather than a `View` modifier so callers
/// can use it inside attributed strings and non-View contexts (which
/// the menu bar renderer does indirectly through controllers).
enum CPUTint {
    static func color(_ percent: Double) -> Color {
        switch percent {
        case ..<25:    return .secondary
        case ..<75:    return .primary
        case ..<150:   return .orange
        default:       return .red
        }
    }
}
