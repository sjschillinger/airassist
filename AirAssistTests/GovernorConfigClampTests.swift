import XCTest
@testable import AirAssist

/// Verifies that persisted values are clamped on load so a corrupted
/// UserDefaults plist can't push the governor or rules engine into
/// unsafe territory.
final class GovernorConfigClampTests: XCTestCase {

    private let governorKey = "governorConfig.v1"
    private let rulesKey    = "throttleRules.v1"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: governorKey)
        UserDefaults.standard.removeObject(forKey: rulesKey)
    }

    func testDefaultConfigIsWithinBounds() {
        let cfg = GovernorConfig()
        XCTAssertGreaterThanOrEqual(cfg.maxTempC, 40)
        XCTAssertLessThanOrEqual(cfg.maxTempC, 100)
        XCTAssertGreaterThanOrEqual(cfg.maxCPUPercent, 50)
        XCTAssertLessThanOrEqual(cfg.maxCPUPercent, 1600)
    }

    func testGovernorTempCeilingClampedOnLoad() {
        // Write a config that exceeds the safety ceiling.
        var cfg = GovernorConfig()
        cfg.maxTempC = 250 // wildly unsafe
        cfg.maxCPUPercent = 9999
        cfg.maxTargets = 999
        cfg.minCPUForTargeting = -5
        let data = try! JSONEncoder().encode(cfg)
        UserDefaults.standard.set(data, forKey: governorKey)

        let loaded = GovernorConfigPersistence.load()
        XCTAssertLessThanOrEqual(loaded.maxTempC, 100)
        XCTAssertLessThanOrEqual(loaded.maxCPUPercent, 1600)
        XCTAssertLessThanOrEqual(loaded.maxTargets, 10)
        XCTAssertGreaterThanOrEqual(loaded.minCPUForTargeting, 5)
    }

    func testThrottleRuleDutyIsClampedOnLoad() {
        let cfg = ThrottleRulesConfig(
            enabled: true,
            rules: [
                ThrottleRule(id: "test.low",  displayName: "Low",  duty: -1.0, isEnabled: true),
                ThrottleRule(id: "test.high", displayName: "High", duty: 99.0, isEnabled: true),
            ]
        )
        let data = try! JSONEncoder().encode(cfg)
        UserDefaults.standard.set(data, forKey: rulesKey)

        let loaded = ThrottleRulesPersistence.load()
        for r in loaded.rules {
            XCTAssertGreaterThanOrEqual(r.duty, ProcessThrottler.minDuty,
                                        "\(r.id) duty below minDuty")
            XCTAssertLessThanOrEqual(r.duty, ProcessThrottler.maxDuty,
                                     "\(r.id) duty above maxDuty")
        }
    }
}
