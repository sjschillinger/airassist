import XCTest
@testable import AirAssist

/// Pin the protection-list contract for `ProcessInspector`. Two
/// tiers — system-hidden (kernel_task etc., never visible anywhere)
/// and user-protected (Xcode, terminals, the agent — visible but
/// not auto-throttled) — and one combined `excludedNames` set kept
/// for back-compat with the governor / rule engine. If any of these
/// shifts, the visibility surfaces' assumptions break.
@MainActor
final class ProcessInspectorProtectionTests: XCTestCase {

    // MARK: - List shape

    func testSystemHiddenContainsCriticalDaemons() {
        // Spot-check the obvious ones. Removing any of these means
        // the user's CPU Activity panel suddenly fills with kernel
        // and window-server noise.
        XCTAssertTrue(ProcessInspector.systemHiddenNames.contains("kernel_task"))
        XCTAssertTrue(ProcessInspector.systemHiddenNames.contains("launchd"))
        XCTAssertTrue(ProcessInspector.systemHiddenNames.contains("WindowServer"))
        XCTAssertTrue(ProcessInspector.systemHiddenNames.contains("AirAssist"))
    }

    func testUserProtectedContainsExpectedApps() {
        // These are the apps where SIGSTOP would be catastrophic.
        // The visibility surfaces show them but disable Cap actions.
        XCTAssertTrue(ProcessInspector.userProtectedNames.contains("Xcode"))
        XCTAssertTrue(ProcessInspector.userProtectedNames.contains("Terminal"))
        XCTAssertTrue(ProcessInspector.userProtectedNames.contains("Claude"))
    }

    func testListsAreDisjoint() {
        // A name should be in exactly one tier — either we don't
        // show it at all (system hidden) or we show but protect it
        // (user protected). Overlap would be a bug.
        let intersection = ProcessInspector.systemHiddenNames
            .intersection(ProcessInspector.userProtectedNames)
        XCTAssertTrue(intersection.isEmpty,
                      "systemHiddenNames and userProtectedNames must be disjoint, found overlap: \(intersection)")
    }

    func testExcludedNamesIsTheUnion() {
        // Back-compat: the original `excludedNames` set used by the
        // governor / rule engine / throttler is exactly the union
        // of the two new tiers. Anything previously excluded is
        // still excluded for throttle-targeting code paths.
        XCTAssertEqual(
            ProcessInspector.excludedNames,
            ProcessInspector.systemHiddenNames.union(ProcessInspector.userProtectedNames)
        )
    }

    // MARK: - isProtected helper

    func testIsProtectedReturnsTrueForUserProtected() {
        for name in ["Xcode", "Simulator", "Claude", "Terminal", "iTerm2", "Warp", "Ghostty"] {
            XCTAssertTrue(ProcessInspector.isProtected(name),
                          "Expected \(name) to be protected")
        }
    }

    func testIsProtectedReturnsFalseForSystemHidden() {
        // System-hidden names are stripped before they reach any
        // visibility surface, so `isProtected` doesn't need to (and
        // shouldn't) say anything about them. The question
        // "is this protected from throttling?" is meaningless for a
        // process the user never sees.
        for name in ["kernel_task", "launchd", "WindowServer", "AirAssist"] {
            XCTAssertFalse(ProcessInspector.isProtected(name),
                           "Expected \(name) to not match isProtected (it's hidden, not protected)")
        }
    }

    func testIsProtectedReturnsFalseForRegularUserApps() {
        // Sanity: ordinary apps that the user can throttle freely
        // shouldn't trip the protection check.
        for name in ["Google Chrome", "Slack", "Spotify", "Notion"] {
            XCTAssertFalse(ProcessInspector.isProtected(name),
                           "Expected \(name) to not be protected")
        }
    }

    // MARK: - Pre-merge regression bait

    func testAirAssistItselfIsHiddenNotProtected() {
        // We never want our own process to show up in the user's
        // CPU Activity list — it's noise. Hidden, not protected.
        XCTAssertTrue(ProcessInspector.systemHiddenNames.contains("AirAssist"))
        XCTAssertFalse(ProcessInspector.userProtectedNames.contains("AirAssist"))
    }
}
