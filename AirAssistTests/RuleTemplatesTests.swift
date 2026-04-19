import XCTest
@testable import AirAssist

/// Sanity guards on the curated rule-template catalog (#57). These are
/// deliberately cheap invariants — the kind of thing that would be
/// embarrassing to ship broken (duplicate IDs silently overwriting each
/// other in a dictionary-style dedupe, a duty of 0 that'd hard-pause an
/// app, a missing bundle ID that'd match nothing). They are not trying
/// to validate the curation judgment itself.
final class RuleTemplatesTests: XCTestCase {

    func testTemplateIDsAreUnique() {
        let ids = RuleTemplates.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate template IDs: \(ids)")
    }

    func testBundleIDsAreUnique() {
        // Two templates pointing at the same bundle ID would make the
        // second enablement silently overwrite the first rule.
        let bundles = RuleTemplates.all.map(\.bundleID)
        XCTAssertEqual(Set(bundles).count, bundles.count, "Duplicate bundle IDs: \(bundles)")
    }

    func testDutyInAcceptedRange() {
        // minDuty < duty <= maxDuty — a template at exactly minDuty would
        // come through as an effective hard-pause which we never want as
        // a default, and above maxDuty would bypass the throttle path.
        for t in RuleTemplates.all {
            XCTAssertGreaterThan(t.duty, ProcessThrottler.minDuty,
                                 "\(t.displayName): duty \(t.duty) at/below minDuty")
            XCTAssertLessThanOrEqual(t.duty, ProcessThrottler.maxDuty,
                                     "\(t.displayName): duty \(t.duty) above maxDuty")
        }
    }

    func testMakeRuleRoundTrip() {
        guard let t = RuleTemplates.all.first else {
            return XCTFail("Template catalog is empty")
        }
        let rule = RuleTemplates.makeRule(from: t, enabled: true)
        XCTAssertEqual(rule.displayName, t.displayName)
        XCTAssertEqual(rule.duty, t.duty)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertNil(rule.schedule, "Templates should not ship with a schedule")
        // ID must be the bundleKey form so rule lookup by bundle ID finds it.
        XCTAssertEqual(rule.id, ThrottleRule.bundleKey(t.bundleID))
    }

    func testDisplayNamesNonEmpty() {
        for t in RuleTemplates.all {
            XCTAssertFalse(t.displayName.isEmpty)
            XCTAssertFalse(t.bundleID.isEmpty)
            XCTAssertFalse(t.rationale.isEmpty)
        }
    }
}
