import XCTest
@testable import AirAssist

/// Locks in the user-facing rename of "Quiet" → "Lap / Cool" and the
/// specific governor numbers that make the rename truthful.
///
/// The whole point of the rename is that this scenario actually keeps a
/// fanless Air's chassis comfortable on the lap *without* throttling so
/// early that normal use feels sluggish. If anyone tunes these numbers
/// without thinking, this test makes them think.
@MainActor
final class ScenarioPresetTests: XCTestCase {

    // MARK: - Display

    func testQuietRawValueIsStableForBackCompat() {
        // Persisted state and the URL-scheme `name=quiet` parameter both
        // depend on the raw value staying `quiet` even after the label
        // changed. Renaming the raw value would orphan saved scenarios
        // and break Shortcuts created before the rename.
        XCTAssertEqual(ScenarioPreset.quiet.rawValue, "quiet")
    }

    func testQuietLabelIsLapCool() {
        XCTAssertEqual(ScenarioPreset.quiet.label, "Lap / Cool")
    }

    func testQuietUsesThermometerSnowflakeSymbol() {
        // Snowflake-on-thermometer reads as "keep this thing cool" to
        // both audiences (fanless and fan-equipped), where the old
        // "wind" symbol only made sense for the fan crowd.
        XCTAssertEqual(ScenarioPreset.quiet.sfSymbol, "thermometer.snowflake")
    }

    // MARK: - Governor values
    //
    // Pinned because the whole point of the rename is that these numbers
    // actually keep an Air's chassis cool without throttling on every
    // brief CPU burst. See the long comment in
    // `ThermalStore.applyScenario(.quiet)` for the reasoning.

    func testLapCoolScenarioAppliesExpectedValues() {
        let store = ThermalStore()
        store.applyScenario(.quiet)
        let c = store.governorConfig

        XCTAssertEqual(c.mode, .temperature,
            "Lap/Cool must use temperature-only mode — CPU% is the wrong instrument for chassis comfort.")
        XCTAssertEqual(c.maxTempC, 78,
            "78°C SoC keeps the palm rest in the lap-comfortable zone.")
        XCTAssertEqual(c.tempHysteresisC, 4,
            "4°C hysteresis = 74-78°C hold band.")
        XCTAssertEqual(c.maxCPUPercent, 600,
            "Generous CPU cap stays dormant under temperature mode but avoids surprising the user if they flip mode later.")
        XCTAssertEqual(c.cpuHysteresisPercent, 50)
        XCTAssertEqual(c.maxTargets, 5)
        XCTAssertEqual(c.minCPUForTargeting, 15)
        XCTAssertFalse(c.onBatteryOnly,
            "Lap comfort matters on AC too — don't gate this scenario on battery state.")
    }

    func testApplyingScenarioPersistsRawName() {
        let store = ThermalStore()
        store.applyScenario(.quiet)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "scenarioPreset.last"),
            "quiet"
        )
    }
}
