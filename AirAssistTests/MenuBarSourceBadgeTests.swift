import XCTest
@testable import AirAssist

/// The source-badge map ties every `SensorCategory` to a single-character
/// label that gets prefixed onto Highest-mode slots in the menu bar.
/// Pinning it down here because three things have to agree:
///
///   1. The character drawn in the bar (`character(for:)`)
///   2. The long-form name VoiceOver speaks (`accessibilityName(for:)`)
///   3. The "Source badge" toggle copy in MenuBarPrefsView, which lists
///      the letters in human-readable order ("C/G/S/B/D")
///
/// If anyone adds a new SensorCategory case, the exhaustive switch in
/// `MenuBarSourceBadge` will fail to compile — but the prefs help text
/// won't, and a regression there would silently mislead the user. The
/// `testEveryCategoryHasNonEmptyAccessibilityName` check at least
/// guarantees VoiceOver doesn't read an empty string for a new case.
final class MenuBarSourceBadgeTests: XCTestCase {

    func testCharacterMapMatchesPrefsCopy() {
        // Lock in the exact letters advertised in the prefs help string.
        // SoC=S because "system on chip" — natural for users.
        // Storage=D ("disk") so it doesn't collide with SoC's S.
        // Other=· (middle dot) flags "miscellaneous" without claiming a letter.
        XCTAssertEqual(MenuBarSourceBadge.character(for: .cpu),     "C")
        XCTAssertEqual(MenuBarSourceBadge.character(for: .gpu),     "G")
        XCTAssertEqual(MenuBarSourceBadge.character(for: .soc),     "S")
        XCTAssertEqual(MenuBarSourceBadge.character(for: .battery), "B")
        XCTAssertEqual(MenuBarSourceBadge.character(for: .storage), "D")
        XCTAssertEqual(MenuBarSourceBadge.character(for: .other),   "·")
    }

    func testCharactersAreSingleGlyphOrShorter() {
        // The renderer reserves a fixed badgeWidth per slot. Anything
        // longer than one glyph would clip or push the value off-frame.
        for cat in SensorCategory.allCases {
            let s = MenuBarSourceBadge.character(for: cat)
            XCTAssertEqual(s.count, 1,
                           "badge for \(cat.rawValue) should be one character, got \(s)")
        }
    }

    func testCharactersAmongFirstFiveAreUnique() {
        // The five "real" categories must each get a distinct letter,
        // otherwise the badge fails its job — disambiguating which
        // sensor won "highest". `.other` deliberately gets a non-letter.
        let realCats: [SensorCategory] = [.cpu, .gpu, .soc, .battery, .storage]
        let chars = realCats.map(MenuBarSourceBadge.character(for:))
        XCTAssertEqual(Set(chars).count, realCats.count,
                       "real categories collide: \(chars)")
    }

    func testEveryCategoryHasNonEmptyAccessibilityName() {
        // A future SensorCategory case would fall through any defaults
        // we forget to update, leaving VoiceOver speechless. Catch it.
        for cat in SensorCategory.allCases {
            let name = MenuBarSourceBadge.accessibilityName(for: cat)
            XCTAssertFalse(name.isEmpty, "no a11y name for \(cat.rawValue)")
            // Long-form reads better than the abbreviation in TTS.
            XCTAssertGreaterThan(name.count, 1,
                                 "a11y name for \(cat.rawValue) should be a word, got \(name)")
        }
    }
}
