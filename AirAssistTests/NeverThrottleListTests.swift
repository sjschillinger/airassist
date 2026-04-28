import XCTest
@testable import AirAssist

/// Safety-critical: the never-throttle list is the user's explicit
/// "do not pause this" promise. A regression that silently dropped or
/// failed to match an entry could let a deliberately-protected app get
/// SIGSTOPped — exactly the failure mode the list exists to prevent.
///
/// Tests run against the standard UserDefaults but use a unique-per-
/// test isolation key by clearing the canonical key in setUp/tearDown.
/// The list reads UserDefaults on every call (no caching), so the
/// tests don't have to fight with notification timing.
final class NeverThrottleListTests: XCTestCase {

    private static let key = "neverThrottleNames"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        super.tearDown()
    }

    func testEmptyByDefault() {
        XCTAssertEqual(NeverThrottleList.names(), [])
        XCTAssertFalse(NeverThrottleList.contains("Anything"))
    }

    func testAddAndContains() {
        NeverThrottleList.add("Xcode")
        NeverThrottleList.add("Slack")
        XCTAssertTrue(NeverThrottleList.contains("Xcode"))
        XCTAssertTrue(NeverThrottleList.contains("Slack"))
        XCTAssertFalse(NeverThrottleList.contains("xcode")) // case-sensitive match
    }

    func testNamesIsSortedCaseInsensitively() {
        NeverThrottleList.add("Xcode")
        NeverThrottleList.add("alacritty")
        NeverThrottleList.add("Safari")
        // Case-insensitive sort: alacritty < Safari < Xcode
        XCTAssertEqual(NeverThrottleList.names(), ["alacritty", "Safari", "Xcode"])
    }

    func testAddIgnoresDuplicatesAndWhitespace() {
        NeverThrottleList.add("Xcode")
        NeverThrottleList.add("Xcode")           // exact dup
        NeverThrottleList.add("  Xcode  ")        // whitespace-only difference, gets trimmed
        XCTAssertEqual(NeverThrottleList.names().count, 1)
    }

    func testAddRejectsEmptyAndWhitespace() {
        NeverThrottleList.add("")
        NeverThrottleList.add("   ")
        NeverThrottleList.add("\t\n")
        XCTAssertEqual(NeverThrottleList.names(), [])
    }

    func testRemove() {
        NeverThrottleList.add("Xcode")
        NeverThrottleList.add("Slack")
        NeverThrottleList.remove("Xcode")
        XCTAssertEqual(NeverThrottleList.names(), ["Slack"])
        XCTAssertFalse(NeverThrottleList.contains("Xcode"))
    }

    func testRemoveOfNonexistentIsNoOp() {
        NeverThrottleList.add("Xcode")
        NeverThrottleList.remove("NotPresent")
        XCTAssertEqual(NeverThrottleList.names(), ["Xcode"])
    }

    func testPersistedKeyMatchesContract() {
        // The key is read by ProcessThrottler.setDuty directly; if this
        // ever drifts, the safety check silently stops working.
        NeverThrottleList.add("Xcode")
        let raw = UserDefaults.standard.stringArray(forKey: "neverThrottleNames")
        XCTAssertEqual(raw, ["Xcode"])
    }
}
