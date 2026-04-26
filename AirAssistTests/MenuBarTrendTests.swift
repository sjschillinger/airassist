import XCTest
@testable import AirAssist

/// `MenuBarTrendCompute` powers the optional ↑/↓ glyph next to each
/// slot value. It needs to:
///
///   - return nil when there isn't enough history (no glyph beats a
///     wrong glyph),
///   - tolerate sensor jitter without flipping (hysteresis is implicit
///     in `flatBandC`, not a separate flip-flop),
///   - report direction symmetrically (a +X°C trend should produce
///     `.rising` exactly as reliably as a −X°C trend produces
///     `.falling`).
///
/// Lock the math here because the renderer trusts the result blindly.
final class MenuBarTrendTests: XCTestCase {

    private func histRising(start: Double = 70, step: Double = 0.6, count: Int = 12) -> [Double] {
        (0..<count).map { start + Double($0) * step }
    }
    private func histFalling(start: Double = 90, step: Double = 0.6, count: Int = 12) -> [Double] {
        (0..<count).map { start - Double($0) * step }
    }

    // MARK: - Insufficient data

    func testEmptyHistoryReturnsNil() {
        XCTAssertNil(MenuBarTrendCompute.compute([]))
    }

    func testTooShortHistoryReturnsNil() {
        // minSamples is 4 — three samples is not enough to claim a trend.
        XCTAssertNil(MenuBarTrendCompute.compute([70, 71, 72]))
    }

    // MARK: - Direction

    func testClearRiseDetected() {
        XCTAssertEqual(MenuBarTrendCompute.compute(histRising()), .rising)
    }

    func testClearFallDetected() {
        XCTAssertEqual(MenuBarTrendCompute.compute(histFalling()), .falling)
    }

    func testFlatHistoryIsFlat() {
        // Same value repeated → delta is exactly 0 → flat.
        let flat = Array(repeating: 75.0, count: 10)
        XCTAssertEqual(MenuBarTrendCompute.compute(flat), .flat)
    }

    // MARK: - Hysteresis

    func testJitterStaysFlat() {
        // ±0.3°C jitter around 75 — under the 0.4°C flat band, must
        // not register as either direction. This is the noise-floor
        // case the band exists for.
        let jittery: [Double] = [75.0, 75.3, 74.8, 75.1, 74.7, 75.2, 74.9, 75.0, 75.1, 74.8]
        XCTAssertEqual(MenuBarTrendCompute.compute(jittery), .flat)
    }

    func testCustomBandClampsBehavior() {
        // With a wider band (1.5°C) even a slow rise reads as flat —
        // proves the threshold is the actual decision point and not
        // hard-coded elsewhere.
        let slow = histRising(start: 70, step: 0.2, count: 10)
        XCTAssertEqual(MenuBarTrendCompute.compute(slow, flatBandC: 1.5), .flat)
        // Same data with a tight band picks up the rise.
        XCTAssertEqual(MenuBarTrendCompute.compute(slow, flatBandC: 0.1), .rising)
    }

    // MARK: - Glyph map

    func testGlyphsAreSingleCharacters() {
        // The renderer reserves a fixed badgeWidth slot for the glyph;
        // anything wider would clip.
        for trend in [MenuBarTrend.rising, .falling, .flat] {
            XCTAssertEqual(MenuBarTrendCompute.glyph(for: trend).count, 1)
        }
    }

    func testGlyphsAreVisuallyDistinct() {
        let rising = MenuBarTrendCompute.glyph(for: .rising)
        let falling = MenuBarTrendCompute.glyph(for: .falling)
        let flat = MenuBarTrendCompute.glyph(for: .flat)
        XCTAssertNotEqual(rising, falling)
        XCTAssertNotEqual(rising, flat)
        XCTAssertNotEqual(falling, flat)
    }
}
