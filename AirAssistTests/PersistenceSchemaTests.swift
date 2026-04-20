import XCTest
@testable import AirAssist

/// Schema-evolution tests for the UserDefaults-backed config blobs.
///
/// Every release ships with a decoder that must be able to read blobs
/// produced by every prior release. When we add a new `ThrottleRule` field
/// or a new `GovernorConfig` knob, we promise two things:
///
///   1. **Forward-safe reads**: old blobs (missing the new field) decode
///      into the new struct with a sensible default.
///   2. **Safe sanitization**: hand-edited / corrupted blobs with
///      out-of-range values clamp to safe territory — they never produce a
///      duty of zero (hard-freeze) or a thermal cap of 200°C.
///
/// These tests feed hand-rolled JSON blobs representing "what an older
/// version would have written" into the current decoder and assert both
/// invariants. They also verify that blobs with *extra* unknown fields
/// (a newer release rolling back to an older one) decode cleanly rather
/// than failing — Codable's default behavior is to ignore unknown keys,
/// but this codifies that assumption as a regression test.
final class PersistenceSchemaTests: XCTestCase {

    // MARK: - Helpers

    /// Decode a `ThrottleRulesConfig` from a literal JSON string, bypassing
    /// `ThrottleRulesPersistence.load()` so we can isolate the Codable
    /// behavior from the UserDefaults round-trip. (The public persistence
    /// helper reads from shared UserDefaults, which is stateful across tests
    /// and bleeds into the app's live config during `xcodebuild test`.)
    private func decodeRules(_ json: String) throws -> ThrottleRulesConfig {
        try JSONDecoder().decode(ThrottleRulesConfig.self, from: Data(json.utf8))
    }

    private func decodeGovernor(_ json: String) throws -> GovernorConfig {
        try JSONDecoder().decode(GovernorConfig.self, from: Data(json.utf8))
    }

    // MARK: - ThrottleRule

    /// Pre-schedule rule blob: no `schedule` field, no `isEnabled` wrapper
    /// history beyond what currently exists. Emulates a v1.0 build writing
    /// defaults that a future build must still decode.
    func testOldThrottleRuleWithoutScheduleDecodes() throws {
        let json = """
        {
          "enabled": true,
          "rules": [
            { "id":"bundleID:com.apple.Safari", "displayName":"Safari",
              "duty":0.6, "isEnabled":true }
          ]
        }
        """
        let cfg = try decodeRules(json)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertNil(cfg.rules[0].schedule,
                     "missing schedule key should default to nil (always-on rule)")
        XCTAssertEqual(cfg.rules[0].duty, 0.6, accuracy: 0.0001)
    }

    /// Blob with unknown fields (a future release wrote something our
    /// decoder doesn't know about). Codable must ignore unknown keys and
    /// decode the rest — never throw, never lose the valid data.
    func testUnknownExtraFieldsAreIgnored() throws {
        let json = """
        {
          "enabled": false,
          "rules": [
            { "id":"bundleID:com.apple.Safari", "displayName":"Safari",
              "duty":0.5, "isEnabled":true,
              "futureField":{"someKnob":42}, "newFlag":true }
          ],
          "version": "v99"
        }
        """
        let cfg = try decodeRules(json)
        XCTAssertEqual(cfg.enabled, false)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertEqual(cfg.rules[0].duty, 0.5, accuracy: 0.0001)
    }

    /// Out-of-range duty values must be clamped by `ThrottleRulesPersistence.load()`.
    /// A hand-edited plist with duty=0 would otherwise produce a permanent
    /// freeze (the throttler never SIGCONTs a duty-0 target), and duty=2
    /// would bypass the release path entirely.
    func testDutyOutOfRangeIsClamped() throws {
        // We can only exercise the clamp via the public load() path, which
        // reads UserDefaults. Use a unique key so we don't clobber app state.
        let defaults = UserDefaults.standard
        let key = "throttleRules.v1"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let json = """
        {
          "enabled": true,
          "rules": [
            { "id":"name:Foo", "displayName":"Foo",   "duty":0.0,  "isEnabled":true },
            { "id":"name:Bar", "displayName":"Bar",   "duty":5.0,  "isEnabled":true },
            { "id":"name:Baz", "displayName":"Baz",   "duty":-0.3, "isEnabled":true }
          ]
        }
        """
        defaults.set(Data(json.utf8), forKey: key)

        let cfg = ThrottleRulesPersistence.load()
        XCTAssertEqual(cfg.rules.count, 3)
        for rule in cfg.rules {
            XCTAssertGreaterThanOrEqual(rule.duty, ProcessThrottler.minDuty,
                "clamp must bring duty up to minDuty — rule \(rule.id) is \(rule.duty)")
            XCTAssertLessThanOrEqual(rule.duty, ProcessThrottler.maxDuty,
                "clamp must pull duty down to maxDuty — rule \(rule.id) is \(rule.duty)")
        }
    }

    /// Completely missing blob → empty default config, never a throw.
    /// This is the "clean install" path and the "corrupted-blob-was-deleted"
    /// recovery path.
    func testMissingDefaultsReturnsEmptyConfig() {
        let defaults = UserDefaults.standard
        let key = "throttleRules.v1"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)

        let cfg = ThrottleRulesPersistence.load()
        XCTAssertFalse(cfg.enabled)
        XCTAssertTrue(cfg.rules.isEmpty)
    }

    // MARK: - GovernorConfig

    /// A v1 blob with every field populated — exercises the main decode
    /// path and confirms no sanitize() trimming occurs for in-range values.
    func testGovernorConfigFullBlobRoundTrips() throws {
        let cfg = GovernorConfig(
            mode: .both, maxTempC: 85, maxCPUPercent: 400,
            tempHysteresisC: 5, cpuHysteresisPercent: 50,
            maxTargets: 4, minCPUForTargeting: 15
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(GovernorConfig.self, from: data)
        XCTAssertEqual(decoded.maxTempC, 85, accuracy: 0.0001)
        XCTAssertEqual(decoded.maxCPUPercent, 400, accuracy: 0.0001)
        XCTAssertEqual(decoded.maxTargets, 4)
    }

    /// Out-of-range governor values must be clamped by the persistence
    /// layer, not silently accepted. A maxTempC of 200°C would let the
    /// governor never fire; a maxCPUPercent of 10000 would let the whole
    /// machine cook.
    func testGovernorClampsDangerousValues() {
        let defaults = UserDefaults.standard
        let key = "governorConfig.v1"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let danger = """
        {
          "mode":"both",
          "maxTempC":200, "maxCPUPercent":10000,
          "tempHysteresisC":200, "cpuHysteresisPercent":2000,
          "maxTargets":100, "minCPUForTargeting":500
        }
        """
        defaults.set(Data(danger.utf8), forKey: key)

        let cfg = GovernorConfigPersistence.load()
        XCTAssertLessThanOrEqual(cfg.maxTempC, 100,
            "maxTempC must be clamped to the 100°C safety ceiling")
        XCTAssertLessThanOrEqual(cfg.maxCPUPercent, 1600,
            "maxCPUPercent must be clamped to the 16-core ceiling")
        XCTAssertLessThanOrEqual(cfg.maxTargets, 10,
            "maxTargets must be clamped so the engine doesn't starve the system")
        XCTAssertLessThanOrEqual(cfg.minCPUForTargeting, 100,
            "minCPUForTargeting clamp must keep the governor addressable")
    }

    /// Governor blob with a missing field (the config ever gains a new
    /// knob and we load a blob from before that release). Default value on
    /// the struct field must supply it. Today all GovernorConfig fields
    /// have defaults, so this verifies the invariant holds.
    func testGovernorConfigToleratesMissingField() throws {
        // Omit `minCPUForTargeting` entirely. Decode should succeed and
        // the field should take its default (currently 15).
        let json = """
        {
          "mode":"temperature",
          "maxTempC":85, "maxCPUPercent":400,
          "tempHysteresisC":5, "cpuHysteresisPercent":50,
          "maxTargets":4
        }
        """
        // Note: today Swift's synthesized init(from:) throws on missing
        // required keys even if the property has a default. If this test
        // fails with a `keyNotFound`, GovernorConfig needs a custom
        // `init(from:)` or an explicit `CodingKeys` + `decodeIfPresent`
        // for each field. Catching it here during Tier 3 is precisely
        // the point of writing this test.
        do {
            _ = try decodeGovernor(json)
        } catch DecodingError.keyNotFound(let key, _) {
            XCTFail("""
            GovernorConfig does not currently tolerate missing field \
            '\(key.stringValue)' in persisted blobs. Older installs that \
            wrote this config before the field was introduced will fall \
            back to the default empty config on load, losing all other \
            user settings. Fix by adding a custom init(from:) that uses \
            decodeIfPresent for every field, or by treating missing keys \
            as "use default" at the persistence layer.
            """)
        } catch {
            XCTFail("unexpected decode error: \(error)")
        }
    }
}
