import Foundation
import XCTest

/// Pause/resume (#35) and Stay-Awake assertion (#36) integration tests.
///
/// Separate file from `ThrottleIntegrationTests` because these don't need to
/// spawn throttle targets and the assertions they make live in different
/// subsystems (ThermalStore pause state, IOPMAssertionCreateWithName).
final class PauseAndStayAwakeTests: XCTestCase {

    private var runner: AirAssistRunner!

    override func setUpWithError() throws {
        continueAfterFailure = false
        runner = try AirAssistRunner()
        try runner.launch()
    }

    override func tearDownWithError() throws {
        // Always turn Stay Awake back off so the IOPMAssertion is released
        // even if a test aborts early.
        runner?.openURL("airassist://debug/stay-awake?mode=off")
        runner?.tearDown()
        runner = nil
    }

    // MARK: - #35 · Pause auto-resumes after duration elapses

    func test_35_PauseAutoResumes() throws {
        // 2-second pause. Background task should flip us back to unpaused.
        runner.openURL("airassist://pause?duration=2s")

        let paused = runner.waitForState(timeout: 2) { s in
            (s["paused"] as? Bool) == true
        }
        XCTAssertNotNil(paused, "pause never registered")

        // Wait past the 2s window, then poll. Allow a short slack for the
        // expiry task to fire.
        Thread.sleep(forTimeInterval: 2.5)
        let resumed = runner.waitForState(timeout: 3) { s in
            (s["paused"] as? Bool) == false
        }
        XCTAssertNotNil(resumed, "pause never auto-resumed after 2s")
    }

    func test_35_ExplicitResumeClearsPause() throws {
        runner.openURL("airassist://pause?duration=forever")
        let paused = runner.waitForState(timeout: 2) { s in
            (s["paused"] as? Bool) == true
        }
        XCTAssertNotNil(paused)

        runner.openURL("airassist://resume")
        let resumed = runner.waitForState(timeout: 2) { s in
            (s["paused"] as? Bool) == false
        }
        XCTAssertNotNil(resumed)
    }

    // MARK: - #36 · Stay-Awake IOPMAssertions land & release correctly

    func test_36_StayAwakeSystemAssertionRegistersWithPMSet() throws {
        runner.openURL("airassist://debug/stay-awake?mode=system")

        // Internal state exported by AirAssist.
        let state = runner.waitForState(timeout: 2) { s in
            (s["stayAwakeMode"] as? String) == "system"
        }
        XCTAssertNotNil(state, "stayAwakeMode never became 'system'")

        // And `pmset -g assertions` should show our assertion. This is the
        // whole point of the feature — internal state alone isn't proof
        // the IOPMAssertion was actually created.
        XCTAssertTrue(pmsetAssertionsMention("PreventUserIdleSystemSleep"),
                      "pmset -g assertions doesn't mention PreventUserIdleSystemSleep. " +
                      "Stay-Awake didn't reach IOKit.")

        runner.openURL("airassist://debug/stay-awake?mode=off")
        let off = runner.waitForState(timeout: 2) { s in
            (s["stayAwakeMode"] as? String) == "off"
        }
        XCTAssertNotNil(off, "stayAwakeMode never reset to off")
    }

    func test_36_StayAwakeDisplayAssertion() throws {
        runner.openURL("airassist://debug/stay-awake?mode=display")

        let state = runner.waitForState(timeout: 2) { s in
            (s["stayAwakeMode"] as? String) == "display"
        }
        XCTAssertNotNil(state)

        XCTAssertTrue(pmsetAssertionsMention("PreventUserIdleDisplaySleep"),
                      "pmset missing PreventUserIdleDisplaySleep for display mode")

        runner.openURL("airassist://debug/stay-awake?mode=off")
    }

    // MARK: - Helpers

    /// True if `pmset -g assertions` output contains `needle`. No regex so
    /// a substring match is enough — we're not parsing the table, just
    /// confirming the assertion type name appears.
    private func pmsetAssertionsMention(_ needle: String) -> Bool {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8) ?? ""
        return str.contains(needle)
    }
}
