import XCTest
@testable import AirAssist

/// Locks in the contract for the `SlotMetric` enum and the value
/// formatting it drives in the menu bar renderer. These are the
/// pure pieces of the Phase 4 metric refactor; the resolution path
/// in `ThermalStore.resolveSlotMetric` is exercised end-to-end via
/// the running app since it depends on the full store.
final class SlotMetricTests: XCTestCase {

    // MARK: - Enum surface

    func testAllCasesPresent() {
        // If a case is added or removed, the menu-bar picker copy
        // and the persistence migration both need updating. This
        // pin makes that a deliberate change, not an accident.
        XCTAssertEqual(
            Set(SlotMetric.allCases),
            [.temperature, .cpuTotal, .none]
        )
    }

    func testRawValuesAreStable() {
        // Persisted in `@AppStorage("menuBarSlot{1,2}Metric")`. Changing
        // any of these is a user-visible reset of their slot config.
        XCTAssertEqual(SlotMetric.temperature.rawValue, "temperature")
        XCTAssertEqual(SlotMetric.cpuTotal.rawValue,    "cpuTotal")
        XCTAssertEqual(SlotMetric.none.rawValue,        "none")
    }

    func testHasSubConfigOnlyForTemperature() {
        XCTAssertTrue(SlotMetric.temperature.hasSubConfig)
        XCTAssertFalse(SlotMetric.cpuTotal.hasSubConfig)
        XCTAssertFalse(SlotMetric.none.hasSubConfig)
    }

    func testLabelsExistForEveryCase() {
        for m in SlotMetric.allCases {
            XCTAssertFalse(m.label.isEmpty,
                           "Missing label for \(m)")
        }
    }

    // MARK: - Value formatting

    func testFormatTemperatureCelsius() {
        let s = MenuBarIconRenderer.formatValue(
            84,
            slotUnit: .temperature,
            tempUnit: .celsius
        )
        XCTAssertTrue(s.contains("84"))
        XCTAssertTrue(s.contains("°"))
    }

    func testFormatTemperatureFahrenheit() {
        // 100°C → 212°F. The exact format string belongs to
        // TempUnit; we just confirm the conversion happened.
        let s = MenuBarIconRenderer.formatValue(
            100,
            slotUnit: .temperature,
            tempUnit: .fahrenheit
        )
        XCTAssertTrue(s.contains("212"))
        XCTAssertTrue(s.contains("°"))
    }

    func testFormatPercent() {
        XCTAssertEqual(
            MenuBarIconRenderer.formatValue(
                42,
                slotUnit: .percent,
                tempUnit: .celsius   // ignored for percent
            ),
            "42%"
        )
    }

    func testFormatPercentRoundsToInt() {
        XCTAssertEqual(
            MenuBarIconRenderer.formatValue(
                42.7,
                slotUnit: .percent,
                tempUnit: .celsius
            ),
            "43%"
        )
    }

    func testFormatPercentIgnoresTempUnit() {
        // The temperature unit must NOT be applied to a percent
        // value — that would silently turn 100% CPU into "212%".
        let asC = MenuBarIconRenderer.formatValue(
            100, slotUnit: .percent, tempUnit: .celsius
        )
        let asF = MenuBarIconRenderer.formatValue(
            100, slotUnit: .percent, tempUnit: .fahrenheit
        )
        XCTAssertEqual(asC, "100%")
        XCTAssertEqual(asF, "100%")
    }

    func testFormatPercentHandlesOver100() {
        // Per-core sum can exceed 100% (8 cores fully pegged = 800%).
        // We don't clamp; we render whatever the source gives us.
        XCTAssertEqual(
            MenuBarIconRenderer.formatValue(
                450, slotUnit: .percent, tempUnit: .celsius
            ),
            "450%"
        )
    }

    // MARK: - CPU thresholds

    func testCPUThresholdConstants() {
        // Pinned because the dashboard, the menu bar tint, and the
        // Phase 5 Preferences UI will all read these. Bumping
        // either is a UX-visible decision.
        //
        // Constants moved from ThermalStore to MenuBarSlotResolver in
        // the post-v0.14 carve-up — they live with the resolution
        // logic, not with the store's general state.
        XCTAssertEqual(MenuBarSlotResolver.cpuTotalWarmPercent, 60)
        XCTAssertEqual(MenuBarSlotResolver.cpuTotalHotPercent,  85)
        XCTAssertGreaterThan(
            MenuBarSlotResolver.cpuTotalHotPercent,
            MenuBarSlotResolver.cpuTotalWarmPercent,
            "Hot must be strictly greater than warm or headroom math goes negative"
        )
    }

    // MARK: - MenuBarSlotState construction

    func testSlotStateDefaultsToTemperatureUnit() {
        // The custom init defaults `unit` to `.temperature` so all
        // pre-Phase-4 call sites continue to compile and behave the
        // same way.
        let s = MenuBarSlotState(
            value: 42,
            sourceCategory: .cpu,
            headroom: 0.5,
            history: [40, 41, 42]
        )
        XCTAssertEqual(s.unit, .temperature)
    }

    func testSlotStateRespectsExplicitPercentUnit() {
        let s = MenuBarSlotState(
            value: 50,
            unit: .percent,
            sourceCategory: nil,
            headroom: nil,
            history: []
        )
        XCTAssertEqual(s.unit, .percent)
    }

    func testEmptySentinelIsTemperature() {
        XCTAssertEqual(MenuBarSlotState.empty.unit, .temperature)
    }
}
