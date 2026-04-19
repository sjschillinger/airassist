import XCTest
@testable import AirAssist

/// Exercises the pure parser helpers on URLSchemeHandler. The actual
/// dispatch is @MainActor + store-side, covered by manual smoke tests.
/// These lock down the wire format — everything here becomes contract
/// for Shortcuts.app actions downstream.
@MainActor
final class URLSchemeHandlerTests: XCTestCase {

    // MARK: - normalizeAction
    //
    // Regression coverage for the integration-suite wedge: before this
    // helper, `airassist://debug/ping` collapsed to `action="debug"` and
    // the debug sub-router bailed as "unknown debug action". Every
    // URL-dispatch site now goes through `normalizeAction`; these tests
    // lock in the wire shapes.

    func testNormalizeHostOnly() {
        let url = URL(string: "airassist://pause")!
        XCTAssertEqual(URLSchemeHandler.normalizeAction(url), "pause")
    }

    func testNormalizeEmptyHostWithPath() {
        // `airassist:///pause` — rarer shape but valid.
        let url = URL(string: "airassist:///pause")!
        XCTAssertEqual(URLSchemeHandler.normalizeAction(url), "pause")
    }

    func testNormalizeHostAndPath() {
        let url = URL(string: "airassist://debug/ping")!
        XCTAssertEqual(URLSchemeHandler.normalizeAction(url), "debug/ping")
    }

    func testNormalizeHostAndPathWithQuery() {
        // Query string must not bleed into the action.
        let url = URL(string: "airassist://debug/ping?to=/tmp/pong.txt")!
        XCTAssertEqual(URLSchemeHandler.normalizeAction(url), "debug/ping")
    }

    func testNormalizeHostAndPathWithDeeperPath() {
        let url = URL(string: "airassist://debug/sub/action")!
        XCTAssertEqual(URLSchemeHandler.normalizeAction(url), "debug/sub/action")
    }

    func testNormalizeLowercases() {
        let url = URL(string: "airassist://Debug/Ping")!
        XCTAssertEqual(URLSchemeHandler.normalizeAction(url), "debug/ping")
    }

    // MARK: - parseDuration

    func testDurationSecondsBare() {
        XCTAssertEqual(URLSchemeHandler.parseDuration("90"), 90)
    }

    func testDurationSecondsSuffix() {
        XCTAssertEqual(URLSchemeHandler.parseDuration("30s"),   30)
        XCTAssertEqual(URLSchemeHandler.parseDuration("30sec"), 30)
    }

    func testDurationMinutes() {
        XCTAssertEqual(URLSchemeHandler.parseDuration("15m"),       15 * 60)
        XCTAssertEqual(URLSchemeHandler.parseDuration("15min"),     15 * 60)
        XCTAssertEqual(URLSchemeHandler.parseDuration("15minutes"), 15 * 60)
    }

    func testDurationHours() {
        XCTAssertEqual(URLSchemeHandler.parseDuration("2h"),     2 * 60 * 60)
        XCTAssertEqual(URLSchemeHandler.parseDuration("2hours"), 2 * 60 * 60)
    }

    func testDurationFractional() {
        XCTAssertEqual(URLSchemeHandler.parseDuration("1.5h"), 1.5 * 60 * 60)
    }

    func testDurationForeverReturnsNil() {
        XCTAssertNil(URLSchemeHandler.parseDuration("forever"))
        XCTAssertNil(URLSchemeHandler.parseDuration("indefinite"))
    }

    func testDurationRejectsGarbage() {
        XCTAssertNil(URLSchemeHandler.parseDuration("eventually"))
        XCTAssertNil(URLSchemeHandler.parseDuration(""))
        XCTAssertNil(URLSchemeHandler.parseDuration("abc"))
    }

    // MARK: - parseDuty

    func testDutyFraction() {
        XCTAssertEqual(URLSchemeHandler.parseDuty("0.5"), 0.5)
    }

    func testDutyPercentWithSign() {
        XCTAssertEqual(URLSchemeHandler.parseDuty("50%"), 0.5)
    }

    func testDutyBareIntegerTreatedAsPercent() {
        // "50" with no suffix could mean 0.5 or 50.0. We pick the only
        // sensible read: percent. This is a documented contract; tests
        // guard it.
        XCTAssertEqual(URLSchemeHandler.parseDuty("50"), 0.5)
    }

    func testDutyClampedToMinDuty() throws {
        // 0% nominal would mean "hard pause" (no SIGCONT). Throttler
        // refuses that; handler clamps up to the minimum.
        let d = try XCTUnwrap(URLSchemeHandler.parseDuty("0"))
        XCTAssertEqual(d, ProcessThrottler.minDuty, accuracy: 1e-9)
    }

    func testDutyClampedToMaxDuty() throws {
        // Over 100% is meaningless but shouldn't crash.
        let d = try XCTUnwrap(URLSchemeHandler.parseDuty("999%"))
        XCTAssertEqual(d, ProcessThrottler.maxDuty, accuracy: 1e-9)
    }

    func testDutyRejectsGarbage() {
        XCTAssertNil(URLSchemeHandler.parseDuty("half"))
        XCTAssertNil(URLSchemeHandler.parseDuty(""))
    }
}
