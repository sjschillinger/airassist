import XCTest

/// Automated accessibility audit (#14/#41).
///
/// Uses XCUITest's `performAccessibilityAudit()` (macOS 14+) — Apple's own
/// static-analysis pass that flags:
///   • Elements without accessibility labels
///   • Contrast-failures against WCAG AA
///   • Elements too small to be a tap/click target
///   • Missing trait information that VoiceOver relies on
///
/// We run it against the Dashboard window. The menu-bar popover is harder
/// to audit automatically because it lives in an NSStatusItem and XCUITest
/// can't easily open it; we rely on manual checks for that window.
///
/// Keyboard-navigation smoke test is bundled in the same file because
/// it's conceptually the same audit: "can someone who doesn't use the
/// trackpad still use every feature?"
@MainActor
final class AccessibilityAuditTests: XCTestCase {

    private var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
    }

    @MainActor
    override func tearDown() async throws {
        app.terminate()
    }

    /// Run Apple's accessibility audit on the Dashboard window.
    /// Failures report the specific element and issue type — the report
    /// appears in the Xcode Test Report navigator with a screenshot.
    func test_dashboardAccessibilityAudit() throws {
        // AirAssist is menu-bar (LSUIElement=true) — no dock, no main window
        // on launch. Open the Dashboard via its URL endpoint (or menu).
        openDashboard()

        // `performAccessibilityAudit` was added in macOS 14. AirAssist's
        // deployment target is 15, so this is always available.
        try app.performAccessibilityAudit { issue in
            // Return false to mark an issue as an expected failure (suppressed).
            // Dynamic-type-contrast on SwiftUI's own Chart axis labels can
            // be a false positive across macOS versions — suppress only
            // those, everything else should surface.
            if let element = issue.element,
               element.elementType == .image,
               element.identifier.hasPrefix("AXChart") {
                return true // ignore
            }
            return false // keep (report as failure)
        }
    }

    /// Preferences window audit.
    func test_preferencesAccessibilityAudit() throws {
        openURL("airassist://debug/open-preferences")
        let target = app.windows.element(boundBy: 0)
        XCTAssertTrue(target.waitForExistence(timeout: 3),
                      "Preferences window never appeared")
        try app.performAccessibilityAudit()
    }

    /// Keyboard-only smoke: open dashboard with ⌘-something, Tab through
    /// controls, confirm each stop has a non-empty accessibility label.
    /// This is a lighter check than the full audit; runs fast and catches
    /// the worst VoiceOver omissions.
    func test_dashboardKeyboardReachesLabeledControls() throws {
        openDashboard()
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Dashboard window missing")

        // Tab 10 times — enough to cycle through the major focusable
        // controls without running past the edge of what SwiftUI exposes.
        for i in 0..<10 {
            app.typeKey("\t", modifierFlags: [])
            // The focused element is whatever has keyboard focus. XCUITest
            // doesn't expose it directly, but the hit-test on the frontmost
            // element gives a close-enough signal.
            let focused = findFocusedElement(in: window)
            if let f = focused {
                XCTAssertFalse(f.label.isEmpty,
                               "Tab \(i): focused element has empty accessibility label " +
                               "(id=\(f.identifier), type=\(f.elementType))")
            }
        }
    }

    // MARK: - Helpers

    /// Opens the main Dashboard window via the debug URL endpoint (only
    /// available in Debug builds). Menu-bar apps can't be driven via an
    /// NSStatusItem click from XCUITest, and AirAssist is LSUIElement=true.
    private func openDashboard() {
        openURL("airassist://debug/open-dashboard")
        _ = app.windows.firstMatch.waitForExistence(timeout: 3)
    }

    private func openURL(_ str: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [str]
        _ = try? task.run()
        task.waitUntilExit()
    }

    private func findFocusedElement(in window: XCUIElement) -> XCUIElement? {
        // The accessibility attribute `isSelected` is the closest proxy for
        // "currently keyboard-focused" that XCUITest exposes on macOS.
        let predicate = NSPredicate(format: "hasKeyboardFocus == YES")
        let match = window.descendants(matching: .any).matching(predicate).firstMatch
        return match.exists ? match : nil
    }
}
