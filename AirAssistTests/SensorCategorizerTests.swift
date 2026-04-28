import XCTest
@testable import AirAssist

/// Pins the heuristic mapping from raw IOHID sensor names to UI
/// categories and display names. The categorizer is the seam between
/// what the OS hands us (`PMU tdie3`, `gas gauge battery`, …) and the
/// dashboard's CPU/GPU/SoC/Battery/Storage groupings — flipping a
/// category silently rearranges every user's dashboard.
///
/// The names tested here are the actual strings the public IOHIDEvent
/// API emits; they're not derived from any private SPI or third-party
/// table. See SensorCategorizer.swift for the source rationale.
final class SensorCategorizerTests: XCTestCase {

    // MARK: - category(for:)

    func testCPUDieMapsToCPU() {
        XCTAssertEqual(SensorCategorizer.category(for: "PMU tdie0"), .cpu)
        XCTAssertEqual(SensorCategorizer.category(for: "PMU tdie5"), .cpu)
    }

    func testGPUDieMapsToGPU() {
        XCTAssertEqual(SensorCategorizer.category(for: "PMU2 tdie0"), .gpu)
        XCTAssertEqual(SensorCategorizer.category(for: "PMU2 tdie3"), .gpu)
    }

    func testGenericPMUMapsToSoC() {
        // Anything that starts with PMU but doesn't match the more specific
        // PMU/PMU2 tdie* prefixes falls through to SoC. Order matters.
        XCTAssertEqual(SensorCategorizer.category(for: "PMU tcal"),  .soc)
        XCTAssertEqual(SensorCategorizer.category(for: "PMU tdev1"), .soc)
    }

    func testBatterySensorsRecognized() {
        XCTAssertEqual(SensorCategorizer.category(for: "gas gauge battery"), .battery)
        XCTAssertEqual(SensorCategorizer.category(for: "Battery Cell 0"),    .battery)
        // Case-insensitive match on the substring.
        XCTAssertEqual(SensorCategorizer.category(for: "GAS GAUGE BATTERY"), .battery)
    }

    func testStorageSensorsRecognized() {
        XCTAssertEqual(SensorCategorizer.category(for: "NAND CH0"), .storage)
        XCTAssertEqual(SensorCategorizer.category(for: "SSD"),      .storage)
    }

    func testUnknownFallsThroughToOther() {
        XCTAssertEqual(SensorCategorizer.category(for: "WeirdNewSensor"),  .other)
        XCTAssertEqual(SensorCategorizer.category(for: ""),                .other)
    }

    // MARK: - displayName(for:)

    func testCPUDieDisplayName() {
        XCTAssertEqual(SensorCategorizer.displayName(for: "PMU tdie0"), "CPU Die 0")
        XCTAssertEqual(SensorCategorizer.displayName(for: "PMU tdie4"), "CPU Die 4")
    }

    func testGPUDieDisplayName() {
        XCTAssertEqual(SensorCategorizer.displayName(for: "PMU2 tdie0"), "GPU Die 0")
        XCTAssertEqual(SensorCategorizer.displayName(for: "PMU2 tdie2"), "GPU Die 2")
    }

    func testCalibrationSensorsKeepReadableNames() {
        XCTAssertEqual(SensorCategorizer.displayName(for: "PMU tcal"),  "PMU Calibration")
        XCTAssertEqual(SensorCategorizer.displayName(for: "PMU2 tcal"), "PMU2 Calibration")
    }

    func testBatteryAndNANDGetFriendlyNames() {
        XCTAssertEqual(SensorCategorizer.displayName(for: "gas gauge battery"), "Battery")
        XCTAssertEqual(SensorCategorizer.displayName(for: "NAND CH0"),          "NAND Storage")
    }

    func testUnknownPassesThroughVerbatim() {
        // Unrecognised names show up in the dashboard literally. Dropping
        // through is preferable to silently renaming something we don't
        // understand.
        XCTAssertEqual(SensorCategorizer.displayName(for: "MysterySensor7"), "MysterySensor7")
    }

    func testTrailingNonIntegerNotRecognized() {
        // "PMU tdieX" matches the prefix but X isn't an Int — fall through
        // to the verbatim name rather than crash on Int(...) returning nil.
        XCTAssertEqual(SensorCategorizer.displayName(for: "PMU tdieX"), "PMU tdieX")
    }
}
