import XCTest
@testable import AirAssist

/// Invariants on the three shipped `ThresholdPreset`s (#58). The preset
/// dropdown is a first-use decision point, and getting the ordering
/// wrong is the kind of mistake a user would legitimately complain
/// about ("Aggressive warns me LATER than Balanced?"). The tests below
/// check the structural guarantees the UI and docs promise:
///
///   1. For every preset, `warm < hot` in every category — otherwise a
///      temperature could be "hot" without ever passing "warm", and the
///      governor's ramp logic would skip stages.
///   2. Monotonic ordering across presets: Aggressive warns at lower
///      temps than Balanced, which in turn warns lower than
///      Conservative. Same for the `hot` threshold.
final class ThresholdPresetTests: XCTestCase {

    private func allCategoryPairs(_ s: ThresholdSettings) -> [(String, CategoryThresholds)] {
        [
            ("cpu",     s.cpu),
            ("gpu",     s.gpu),
            ("soc",     s.soc),
            ("battery", s.battery),
            ("storage", s.storage),
            ("other",   s.other),
        ]
    }

    func testWarmBelowHotInEveryCategoryForEveryPreset() {
        for preset in ThresholdPreset.allCases {
            for (name, t) in allCategoryPairs(preset.settings) {
                XCTAssertLessThan(t.warm, t.hot,
                                  "\(preset.rawValue)/\(name): warm \(t.warm) must be < hot \(t.hot)")
            }
        }
    }

    func testMonotonicAcrossPresets() {
        // Aggressive <= Balanced <= Conservative for both warm and hot,
        // category-by-category. We use <= (not strict <) because Balanced
        // is the design baseline and some categories may coincide with
        // Aggressive at the low end or Conservative at the high end; what
        // matters is that the ordering is never inverted.
        let aggList  = allCategoryPairs(ThresholdPreset.aggressive.settings)
        let balList  = allCategoryPairs(ThresholdPreset.balanced.settings)
        let consList = allCategoryPairs(ThresholdPreset.conservative.settings)
        XCTAssertEqual(aggList.count, balList.count)
        XCTAssertEqual(balList.count, consList.count)

        for i in aggList.indices {
            let (name, a) = aggList[i]
            let b         = balList[i].1
            let c         = consList[i].1
            XCTAssertLessThanOrEqual(a.warm, b.warm,
                                     "\(name): aggressive.warm \(a.warm) > balanced.warm \(b.warm)")
            XCTAssertLessThanOrEqual(b.warm, c.warm,
                                     "\(name): balanced.warm \(b.warm) > conservative.warm \(c.warm)")
            XCTAssertLessThanOrEqual(a.hot, b.hot,
                                     "\(name): aggressive.hot \(a.hot) > balanced.hot \(b.hot)")
            XCTAssertLessThanOrEqual(b.hot, c.hot,
                                     "\(name): balanced.hot \(b.hot) > conservative.hot \(c.hot)")
        }
    }

    func testLabelsAndTaglinesPresent() {
        for preset in ThresholdPreset.allCases {
            XCTAssertFalse(preset.label.isEmpty)
            XCTAssertFalse(preset.tagline.isEmpty)
        }
    }
}
