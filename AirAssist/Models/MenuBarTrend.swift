import Foundation

/// Slope of a slot's recent history, expressed as a tri-state suitable
/// for a single-glyph hint in the menu bar. The value itself is what
/// the user reads first; the arrow answers "is this still going up,
/// or did it just spike and recover?" without forcing them to open
/// the popover.
enum MenuBarTrend: String, Sendable, Equatable {
    case rising
    case falling
    case flat
}

enum MenuBarTrendCompute {
    /// Threshold below which we report `.flat`. Calibrated so a
    /// sensor jittering ±0.3 °C between samples doesn't flicker the
    /// glyph — the eye is much more sensitive to glyph flips than to
    /// a degree of variation, so this errs on the side of stability
    /// over freshness. Same value works fine for percent metrics —
    /// 0.4% is well below the noise floor of the CPU% reading.
    static let flatBandC: Double = 0.4

    /// Minimum history length to make a slope claim. Below this,
    /// return nil so the renderer hides the glyph rather than guessing
    /// from two samples.
    static let minSamples: Int = 4

    /// Compare the mean of the latest third of `history` against the
    /// mean of the earliest third — gives a smoothed slope sign
    /// without needing real linear regression. Middle samples are
    /// ignored on purpose: they make the comparison less sensitive to
    /// a single outlier in the middle of the window.
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
    /// and a middle dot for flat is calmer than a horizontal bar.
    /// Returns the literal glyph; callers decide whether to suppress
    /// the `.flat` case.
    static func glyph(for trend: MenuBarTrend) -> String {
        switch trend {
        case .rising:  return "↑"
        case .falling: return "↓"
        case .flat:    return "·"
        }
    }
}
