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
            if self.shouldSuppress(issue) { return true }
            self.logAuditIssue("Dashboard", issue)
            return false // keep
        }
    }

    /// Preferences window audit.
    func test_preferencesAccessibilityAudit() throws {
        openURL("airassist://debug/open-preferences")
        let target = app.windows.element(boundBy: 0)
        XCTAssertTrue(target.waitForExistence(timeout: 3),
                      "Preferences window never appeared")
        try app.performAccessibilityAudit { issue in
            if self.shouldSuppress(issue) { return true }
            self.logAuditIssue("Preferences", issue)
            return false
        }
    }

    /// Suppressions for Apple-audit false-positives that we've investigated.
    private func shouldSuppress(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard let element = issue.element else { return false }

        // SwiftUI Chart axis labels false-positive on dynamic-type contrast
        // across macOS versions.
        if element.elementType == .image,
           element.identifier.hasPrefix("AXChart") {
            return true
        }

        // `.action` audit type (rawValue 4294967296) flags popUpButtons as
        // "Action is missing" because the audit checks for explicit
        // AXIncrement / AXDecrement-style actions that don't apply to menu
        // pickers. NSPopUpButton-backed SwiftUI `Picker`s do have AXPress
        // and are fully operable via VoiceOver — the audit just doesn't
        // recognize the action shape. Verified by manual VoiceOver pass
        // 2026-04-19.
        if issue.auditType.rawValue == 4_294_967_296,
           element.elementType == .popUpButton {
            return true
        }

        // Unlabeled non-interactive containers that SwiftUI emits for layout
        // (group, other, scrollView, table/list layout artifacts, titlebar
        // implementation views). The audit flags these under:
        //  - `.elementDetail` (rawValue 8)              — "has no description"
        //  - `.parentChild`   (rawValue 8589934592)     — "Parent/Child mismatch"
        //
        // Fixing them would mean wrapping every Section / LazyVGrid / etc.
        // in a `.accessibilityElement(children: .contain)` with a synthetic
        // label — this would COLLAPSE VoiceOver navigation so individual
        // children are no longer focusable. Net accessibility loss.
        //
        // The audits we *still* enforce are the interactive-control checks:
        // missing labels on buttons / pickers / toggles / textfields / sliders,
        // contrast, hit-region size, trait conflicts. Those DO produce
        // real bugs and are not suppressed here.
        //
        // Verified 2026-04-19: manual VoiceOver pass over Dashboard and
        // Preferences reads every focusable control by name and traits.
        let nonInteractiveTypes: Set<XCUIElement.ElementType> = [
            .group, .other, .scrollView, .table, .outline, .cell, .disclosureTriangle,
        ]
        let isUnlabeledContainer = element.label.isEmpty
            && element.identifier.isEmpty
            && (nonInteractiveTypes.contains(element.elementType)
                || element.elementType.rawValue >= 70) // layout-only AppKit views
        if isUnlabeledContainer {
            let auditRaw = issue.auditType.rawValue
            if auditRaw == 8 || auditRaw == 8_589_934_592 {
                return true
            }
        }

        // Contrast audits on SensorCardView's `.cool` state. The system
        // `.green` used for the 22pt temperature reading against
        // `.regularMaterial` falls below WCAG AA large-text (3:1) in light
        // mode. Visual design is explicitly locked for v1.0 per
        // LAUNCH_CHECKLIST #9/#10 ("accepted as shipping"). Post-launch
        // follow-up: replace `.green`/`.orange`/`.red` in SensorCardView
        // with a palette that meets AA on both materials. Tracked as
        // TODO_POST_LAUNCH in SensorCardView.swift.
        if issue.auditType.rawValue == 1, // .contrast
           element.label.contains(", cool")
            || element.label.contains(", warm")
            || element.label.contains(", hot") {
            print("[#14] suppressed contrast audit on locked-design element: \(element.label)")
            return true
        }

        return false
    }

    /// Dump as much as XCUITest exposes about an audit issue. The audit
    /// error itself is very terse ("Element has no description") — this
    /// logs element type, identifier, label, frame, and enclosing window
    /// so we can actually find the offender without opening Xcode.
    private func logAuditIssue(_ where_: String, _ issue: XCUIAccessibilityAuditIssue) {
        let e = issue.element
        let lines: [String] = [
            "[#14] \(where_) a11y issue: \(issue.auditType) — \(issue.compactDescription)",
            "      element: type=\(e?.elementType.rawValue ?? 0) " +
                "id=\"\(e?.identifier ?? "")\" " +
                "label=\"\(e?.label ?? "")\" " +
                "value=\"\(String(describing: e?.value))\"",
            "      frame:   \(String(describing: e?.frame))",
        ]
        for line in lines { print(line) }
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
