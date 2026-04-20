import XCTest
@testable import AirAssist

/// Unit tests for the pure-logic surface of `UpdateCheckService`. We
/// don't exercise the URLSession path here — that would require a
/// network stub layer the service deliberately doesn't expose, and the
/// network path is trivially wrong-or-right from reading the call site.
///
/// What we DO cover:
///   - The semver comparator (it's load-bearing for the "is there a
///     newer version?" decision — get this wrong and every user who
///     upgrades past 0.9.0 gets a permanent false nudge to upgrade to
///     an older version).
///   - Tag normalization (leading `v`, whitespace).
///   - The pre-release suffix handling (we compare on the numeric core
///     but display the full tag).
final class UpdateCheckServiceTests: XCTestCase {

    // MARK: - compare()

    func testCompareEqualVersions() {
        XCTAssertEqual(UpdateCheckService.compare("0.9.0", "0.9.0"), .orderedSame)
        XCTAssertEqual(UpdateCheckService.compare("1.0.0", "1.0.0"), .orderedSame)
    }

    func testCompareNewerPatch() {
        XCTAssertEqual(UpdateCheckService.compare("0.9.1", "0.9.0"), .orderedDescending)
    }

    func testCompareNewerMinor() {
        XCTAssertEqual(UpdateCheckService.compare("0.10.0", "0.9.9"), .orderedDescending,
                       "0.10.0 must beat 0.9.9 — numeric, not lexicographic")
    }

    func testCompareNewerMajor() {
        XCTAssertEqual(UpdateCheckService.compare("1.0.0", "0.99.99"), .orderedDescending)
    }

    func testCompareOlder() {
        XCTAssertEqual(UpdateCheckService.compare("0.9.0", "0.9.1"), .orderedAscending)
        XCTAssertEqual(UpdateCheckService.compare("0.9.0", "1.0.0"), .orderedAscending)
    }

    func testLeadingVIsStripped() {
        XCTAssertEqual(UpdateCheckService.compare("v0.9.1", "0.9.0"), .orderedDescending)
        XCTAssertEqual(UpdateCheckService.compare("V0.9.1", "v0.9.0"), .orderedDescending)
        XCTAssertEqual(UpdateCheckService.compare("v0.9.0", "v0.9.0"), .orderedSame)
    }

    func testWhitespaceTolerant() {
        XCTAssertEqual(UpdateCheckService.compare(" 0.9.1 ", "0.9.0"), .orderedDescending)
        XCTAssertEqual(UpdateCheckService.compare("\n0.9.0\t", "0.9.0"), .orderedSame)
    }

    /// `0.9.0-beta.1` should compare equal to `0.9.0` because we ignore
    /// pre-release suffixes. This is intentional: we don't want a stable
    /// `0.9.0` release to tell users of `0.9.0-beta.1` they need to
    /// "upgrade" — they have the same user-visible version. If we ever
    /// ship pre-releases publicly we'll revisit.
    func testPreReleaseSuffixIgnoredInCompare() {
        XCTAssertEqual(UpdateCheckService.compare("0.9.0-beta.1", "0.9.0"), .orderedSame)
        XCTAssertEqual(UpdateCheckService.compare("0.9.0+build.42", "0.9.0"), .orderedSame)
        XCTAssertEqual(UpdateCheckService.compare("1.0.0-rc.1", "0.9.9"), .orderedDescending)
    }

    func testShorterVersionsPadWithZero() {
        // "1.0" should parse as "1.0.0" for comparison — GitHub tags are
        // free-form and a forker might cut "v1.0" instead of "v1.0.0".
        XCTAssertEqual(UpdateCheckService.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateCheckService.compare("1.0.1", "1.0"), .orderedDescending)
        XCTAssertEqual(UpdateCheckService.compare("2", "1.99.99"), .orderedDescending)
    }

    // MARK: - currentVersion

    /// `currentVersion` reads the running bundle's
    /// `CFBundleShortVersionString`. In the test harness that's the
    /// test host's Info.plist, which is set by project.yml and should
    /// never be empty or the fallback `"0.0.0"`. If this ever flips to
    /// `0.0.0` it means project.yml regressed.
    func testCurrentVersionIsParseable() {
        let v = UpdateCheckService.currentVersion
        XCTAssertFalse(v.isEmpty)
        XCTAssertNotEqual(v, "0.0.0",
                          "bundle version fell through to the fallback — " +
                          "CFBundleShortVersionString missing from Info.plist?")
        // It should compare equal to itself and to its v-prefixed form.
        XCTAssertEqual(UpdateCheckService.compare(v, v), .orderedSame)
        XCTAssertEqual(UpdateCheckService.compare("v" + v, v), .orderedSame)
    }
}
