import XCTest
@testable import AirAssist

/// Exercises the pure parser helpers on URLSchemeHandler. The actual
/// dispatch is @MainActor + store-side, covered by manual smoke tests.
/// These lock down the wire format — everything here becomes contract
/// for Shortcuts.app actions downstream.
@MainActor
final class URLSchemeHandlerTests: XCTestCase {

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
