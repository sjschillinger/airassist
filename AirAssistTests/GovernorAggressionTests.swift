import XCTest
@testable import AirAssist

/// Unit tests for the new aggression inputs added in 0.10 prep:
/// - `onBatteryOnly` gate (nothing fires while on AC when flag is set)
/// - `respectOSThermalState` fold-in via `ThermalGovernor.biasFor(_:)`
/// - Schema-safe decode for both new fields
///
/// Keep these pure-value checks — avoid spinning up a full governor
/// (which would need a real `ProcessSnapshotPublisher` / `ProcessThrottler`
/// tree). The governor-tick integration path is covered by
/// `AirAssistIntegrationRunner`.
final class GovernorAggressionTests: XCTestCase {

    // MARK: biasFor mapping

    func testBiasForThermalStateIsMonotonic() {
        let nominal  = ThermalGovernor.biasFor(.nominal)
        let fair     = ThermalGovernor.biasFor(.fair)
        let serious  = ThermalGovernor.biasFor(.serious)
        let critical = ThermalGovernor.biasFor(.critical)

        XCTAssertEqual(nominal, 0.0, "nominal must not bias duty at all")
        XCTAssertLessThan(nominal,  fair)
        XCTAssertLessThan(fair,     serious)
        XCTAssertLessThan(serious,  critical)
        XCTAssertEqual(critical, 1.0, "critical should saturate the bias")

        // All values must be in [0,1] — the `max(...)` fold assumes it.
        for v in [nominal, fair, serious, critical] {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }

    // MARK: GovernorConfig defaults

    func testDefaultsAreSafeForNewFields() {
        let cfg = GovernorConfig()
        XCTAssertFalse(cfg.onBatteryOnly,
            "onBatteryOnly must default off — changing power-source behaviour silently would surprise upgraders.")
        XCTAssertTrue(cfg.respectOSThermalState,
            "respectOSThermalState is on by default — the signal is free and strictly additive.")
    }

    // MARK: Schema-safe decode

    private let governorKey = "governorConfig.v1"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: governorKey)
    }

    func testOldPersistedBlobKeepsDefaultsForNewFields() throws {
        // Write a JSON blob shaped like a pre-0.10 config — the two new
        // fields are absent. `decodeIfPresent` must fall back to the
        // struct-level defaults rather than silently wiping the whole
        // config.
        let legacy = """
        {
          "mode": "both",
          "maxTempC": 90,
          "maxCPUPercent": 400,
          "tempHysteresisC": 4,
          "cpuHysteresisPercent": 60,
          "maxTargets": 3,
          "minCPUForTargeting": 20
        }
        """
        UserDefaults.standard.set(legacy.data(using: .utf8), forKey: governorKey)
        let loaded = GovernorConfigPersistence.load()

        // User-set fields survive.
        XCTAssertEqual(loaded.mode, .both)
        XCTAssertEqual(loaded.maxTempC, 90)
        XCTAssertEqual(loaded.maxCPUPercent, 400)

        // New fields fall back to struct defaults.
        XCTAssertFalse(loaded.onBatteryOnly)
        XCTAssertTrue(loaded.respectOSThermalState)
    }

    func testNewFieldsRoundTripThroughPersistence() throws {
        var cfg = GovernorConfig()
        cfg.mode = .temperature
        cfg.onBatteryOnly = true
        cfg.respectOSThermalState = false
        let data = try JSONEncoder().encode(cfg)
        UserDefaults.standard.set(data, forKey: governorKey)

        let loaded = GovernorConfigPersistence.load()
        XCTAssertTrue(loaded.onBatteryOnly)
        XCTAssertFalse(loaded.respectOSThermalState)
    }
}
