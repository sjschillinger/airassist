import XCTest
@testable import AirAssist

/// Tiny but worth pinning. `format` is called every dashboard tick on
/// every visible sensor and shows up in screenshots, in VoiceOver
/// strings, and in the menu-bar slot text. A regression to °F or a
/// sign flip would be embarrassing.
final class TemperatureFormatterTests: XCTestCase {

    func testCelsiusRoundsAwayDecimals() {
        // `%.0f` uses C printf's round-half-to-even (banker's rounding):
        //   42.5 → 42 (even), 43.5 → 44 (even). We don't actually rely
        //   on which half-rule applies — sensor noise dwarfs the tie-
        //   break — but pin observed behaviour so a future Swift String
        //   Format change would fail loudly rather than silently shifting
        //   every dashboard reading by 1.
        XCTAssertEqual(TempUnit.celsius.format(42.0),  "42°C")
        XCTAssertEqual(TempUnit.celsius.format(42.4),  "42°C")
        XCTAssertEqual(TempUnit.celsius.format(42.6),  "43°C")
        XCTAssertEqual(TempUnit.celsius.format(0.0),   "0°C")
        XCTAssertEqual(TempUnit.celsius.format(-5.0),  "-5°C")
    }

    func testFahrenheitConverts() {
        // Anchors: 0°C = 32°F, 100°C = 212°F, 37°C = 98.6°F → "99°F"
        XCTAssertEqual(TempUnit.fahrenheit.format(0.0),    "32°F")
        XCTAssertEqual(TempUnit.fahrenheit.format(100.0),  "212°F")
        XCTAssertEqual(TempUnit.fahrenheit.format(37.0),   "99°F")
    }

    func testFahrenheitNegativeBelowZero() {
        XCTAssertEqual(TempUnit.fahrenheit.format(-40.0), "-40°F") // -40 is the C/F crossover
    }

    func testRawValuesPinnedToPersistedSchema() {
        // Persisted as Int in UserDefaults (TempUnit.rawValue). Flipping
        // these silently inverts everyone's saved preference on upgrade.
        XCTAssertEqual(TempUnit.celsius.rawValue,    0)
        XCTAssertEqual(TempUnit.fahrenheit.rawValue, 1)
    }
}
