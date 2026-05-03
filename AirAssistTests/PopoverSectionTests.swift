import XCTest
@testable import AirAssist

/// Locks in the contract for popover-section persistence.
///
/// Two storage concerns, tested independently then together:
///   - **order** (`currentOrder`, `reorder`) — full list of sections
///     in display order
///   - **visibility** (`isVisible`, `setVisible`, `hiddenSet`) — set
///     of hidden sections
///
/// Each test uses an isolated `UserDefaults` suite so they don't
/// leak state between cases or into the user's real preferences.
final class PopoverSectionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PopoverSectionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultOrderIsCanonical() {
        XCTAssertEqual(
            PopoverSectionPrefs.currentOrder(defaults: defaults),
            PopoverSection.allCases
        )
    }

    func testDefaultHiddenSetIsEmpty() {
        XCTAssertTrue(PopoverSectionPrefs.hiddenSet(defaults: defaults).isEmpty)
    }

    func testDefaultsHaveEverythingVisible() {
        for section in PopoverSection.allCases {
            XCTAssertTrue(
                PopoverSectionPrefs.isVisible(section, defaults: defaults),
                "Expected \(section) to be visible by default"
            )
        }
    }

    func testDefaultVisibleOrderedMatchesCanonical() {
        XCTAssertEqual(
            PopoverSectionPrefs.visibleOrdered(defaults: defaults),
            PopoverSection.allCases
        )
    }

    // MARK: - Visibility (independent of order)

    func testHidingSectionRemovesFromVisible() {
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        XCTAssertFalse(PopoverSectionPrefs.isVisible(.cpuActivity, defaults: defaults))
        XCTAssertTrue(PopoverSectionPrefs.isVisible(.sensors, defaults: defaults))
        XCTAssertTrue(PopoverSectionPrefs.isVisible(.controls, defaults: defaults))
    }

    func testHidingSectionDoesNotChangeOrder() {
        // Hiding shouldn't touch the order array — it lives in a
        // separate key so the user's chosen order survives toggling.
        let beforeOrder = PopoverSectionPrefs.currentOrder(defaults: defaults)
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        let afterOrder = PopoverSectionPrefs.currentOrder(defaults: defaults)
        XCTAssertEqual(beforeOrder, afterOrder)
    }

    func testShowingPreviouslyHiddenSection() {
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        PopoverSectionPrefs.setVisible(.cpuActivity, true, defaults: defaults)
        XCTAssertTrue(PopoverSectionPrefs.isVisible(.cpuActivity, defaults: defaults))
    }

    func testHidingTwiceIsSafe() {
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        XCTAssertFalse(PopoverSectionPrefs.isVisible(.cpuActivity, defaults: defaults))
        // Hidden set should contain exactly one entry, not two.
        XCTAssertEqual(PopoverSectionPrefs.hiddenSet(defaults: defaults).count, 1)
    }

    func testCanHideEverything() {
        // Edge case: support hiding every section. Phase 5 UI will
        // likely warn against this, but the data layer is neutral.
        for section in PopoverSection.allCases {
            PopoverSectionPrefs.setVisible(section, false, defaults: defaults)
        }
        XCTAssertTrue(PopoverSectionPrefs.visibleOrdered(defaults: defaults).isEmpty)
    }

    // MARK: - Reorder (independent of visibility)

    func testReorderPersists() {
        let custom: [PopoverSection] = [
            .controls, .cpuActivity, .sensors, .governorStatus, .manualThrottles
        ]
        PopoverSectionPrefs.reorder(custom, defaults: defaults)
        XCTAssertEqual(
            PopoverSectionPrefs.currentOrder(defaults: defaults),
            custom
        )
    }

    func testReorderDoesNotChangeVisibility() {
        // Hide cpuActivity, then reorder. cpuActivity should stay
        // hidden — order and visibility are independent.
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        PopoverSectionPrefs.reorder(
            [.controls, .sensors, .cpuActivity, .governorStatus, .manualThrottles],
            defaults: defaults
        )
        XCTAssertFalse(PopoverSectionPrefs.isVisible(.cpuActivity, defaults: defaults))
    }

    func testVisibleOrderedReflectsBothOrderAndHidden() {
        // Reorder with everything, then hide one — visibleOrdered
        // returns the rest in the new order.
        PopoverSectionPrefs.reorder(
            [.controls, .sensors, .cpuActivity, .governorStatus, .manualThrottles],
            defaults: defaults
        )
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        XCTAssertEqual(
            PopoverSectionPrefs.visibleOrdered(defaults: defaults),
            [.controls, .sensors, .governorStatus, .manualThrottles]
        )
    }

    // MARK: - Reset

    func testResetToDefaults() {
        PopoverSectionPrefs.setVisible(.cpuActivity, false, defaults: defaults)
        PopoverSectionPrefs.setVisible(.controls, false, defaults: defaults)
        PopoverSectionPrefs.reorder(
            [.controls, .cpuActivity, .sensors, .governorStatus, .manualThrottles],
            defaults: defaults
        )
        PopoverSectionPrefs.resetToDefaults(defaults: defaults)
        XCTAssertEqual(
            PopoverSectionPrefs.currentOrder(defaults: defaults),
            PopoverSection.allCases
        )
        XCTAssertTrue(PopoverSectionPrefs.hiddenSet(defaults: defaults).isEmpty)
    }

    // MARK: - Forward / backward compatibility

    func testUnknownSavedRawValueInOrderIsFiltered() {
        // Future release saved a section name we don't know about.
        // Drop it on read; merge in any cases not in the saved list
        // so users don't lose access to existing sections.
        let raw = #"["sensors","memoryActivity","controls"]"#
        defaults.set(raw, forKey: PopoverSectionPrefs.orderKey)

        let order = PopoverSectionPrefs.currentOrder(defaults: defaults)
        XCTAssertEqual(order.first, .sensors)
        XCTAssertEqual(order[1], .controls)
        // mergeUnknowns appends remaining allCases at the end.
        XCTAssertTrue(order.contains(.cpuActivity))
        XCTAssertTrue(order.contains(.manualThrottles))
        XCTAssertTrue(order.contains(.governorStatus))
        XCTAssertEqual(order.count, PopoverSection.allCases.count)
    }

    func testUnknownSavedRawValueInHiddenIsFiltered() {
        // Same forward-compat treatment for the hidden set.
        let raw = #"["cpuActivity","memoryActivity"]"#
        defaults.set(raw, forKey: PopoverSectionPrefs.hiddenKey)

        let hidden = PopoverSectionPrefs.hiddenSet(defaults: defaults)
        XCTAssertEqual(hidden, [.cpuActivity])
    }

    func testNewCaseAddedInLaterReleaseIsAppendedToOrder() {
        // User saved a partial list (everything that existed at the
        // time of save). On read, mergeUnknowns appends any cases
        // now in allCases that weren't in the saved list.
        let partial: [PopoverSection] = [.sensors, .controls]
        PopoverSectionPrefs.reorder(partial, defaults: defaults)
        let order = PopoverSectionPrefs.currentOrder(defaults: defaults)
        // The two saved sections come first…
        XCTAssertEqual(order.prefix(2), [.sensors, .controls])
        // …and any additional cases are appended.
        XCTAssertEqual(order.count, PopoverSection.allCases.count)
    }

    func testCorruptStorageFallsBackToDefaults() {
        defaults.set("not-valid-json", forKey: PopoverSectionPrefs.orderKey)
        defaults.set("{not-an-array", forKey: PopoverSectionPrefs.hiddenKey)
        XCTAssertEqual(
            PopoverSectionPrefs.currentOrder(defaults: defaults),
            PopoverSection.allCases
        )
        XCTAssertTrue(PopoverSectionPrefs.hiddenSet(defaults: defaults).isEmpty)
    }
}
