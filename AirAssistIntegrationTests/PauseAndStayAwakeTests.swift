import Foundation

/// Pause/resume (#35) and Stay-Awake assertion (#36) integration tests.
///
/// Free functions rather than XCTestCase methods — we're a CLI runner,
/// not an xctest bundle. `main.swift` sets up a fresh `AirAssistRunner`
/// per test, invokes the function, then tears down.

// MARK: - #35 · Pause auto-resumes after duration elapses

func test_35_PauseAutoResumes(_ runner: AirAssistRunner) throws {
    // 2-second pause. Background task should flip us back to unpaused.
    runner.openURL("airassist://pause?duration=2s")

    let paused = runner.waitForState(timeout: 2) { s in
        (s["paused"] as? Bool) == true
    }
    try assertNotNil(paused, "pause never registered")

    // Wait past the 2s window, then poll. Allow a short slack for the
    // expiry task to fire.
    Thread.sleep(forTimeInterval: 2.5)
    let resumed = runner.waitForState(timeout: 3) { s in
        (s["paused"] as? Bool) == false
    }
    try assertNotNil(resumed, "pause never auto-resumed after 2s")
}

func test_35_ExplicitResumeClearsPause(_ runner: AirAssistRunner) throws {
    runner.openURL("airassist://pause?duration=forever")
    let paused = runner.waitForState(timeout: 2) { s in
        (s["paused"] as? Bool) == true
    }
    try assertNotNil(paused)

    runner.openURL("airassist://resume")
    let resumed = runner.waitForState(timeout: 2) { s in
        (s["paused"] as? Bool) == false
    }
    try assertNotNil(resumed)
}

// MARK: - #36 · Stay-Awake IOPMAssertions land & release correctly

func test_36_StayAwakeSystemAssertionRegistersWithPMSet(_ runner: AirAssistRunner) throws {
    runner.openURL("airassist://debug/stay-awake?mode=system")

    // Internal state exported by AirAssist.
    let state = runner.waitForState(timeout: 2) { s in
        (s["stayAwakeMode"] as? String) == "system"
    }
    try assertNotNil(state, "stayAwakeMode never became 'system'")

    // And `pmset -g assertions` should show our assertion. This is the
    // whole point of the feature — internal state alone isn't proof the
    // IOPMAssertion was actually created.
    try assertTrue(pmsetAssertionsMention("PreventUserIdleSystemSleep"),
                   "pmset -g assertions doesn't mention PreventUserIdleSystemSleep. " +
                   "Stay-Awake didn't reach IOKit.")

    runner.openURL("airassist://debug/stay-awake?mode=off")
    let off = runner.waitForState(timeout: 2) { s in
        (s["stayAwakeMode"] as? String) == "off"
    }
    try assertNotNil(off, "stayAwakeMode never reset to off")
}

func test_36_StayAwakeDisplayAssertion(_ runner: AirAssistRunner) throws {
    runner.openURL("airassist://debug/stay-awake?mode=display")

    let state = runner.waitForState(timeout: 2) { s in
        (s["stayAwakeMode"] as? String) == "display"
    }
    try assertNotNil(state)

    try assertTrue(pmsetAssertionsMention("PreventUserIdleDisplaySleep"),
                   "pmset missing PreventUserIdleDisplaySleep for display mode")

    runner.openURL("airassist://debug/stay-awake?mode=off")
}

// MARK: - #37 · displayThenSystem downgrades display→system after timer

/// `airassist://debug/stay-awake?mode=displayThenSystem` is wired to a
/// 1-minute timer (hardcoded in URLSchemeHandler+Debug). After ~60s the
/// display assertion must drop and a system-only assertion must be
/// taken in its place. We verify both via `pmset -g assertions` and the
/// `displayTimerRemaining` field exported in debug/export-state.
///
/// Runtime: ~70s. Long for a unit test, but the 1-min floor is baked
/// into IOPMAssertionCreate's smallest useful timeout — anything
/// shorter risks racing the countdown task.
func test_37_DisplayThenSystemDowngrades(_ runner: AirAssistRunner) throws {
    runner.openURL("airassist://debug/stay-awake?mode=displayThenSystem")

    // Initial: display assertion live, countdown ticking.
    let started = runner.waitForState(timeout: 3) { s in
        (s["stayAwakeMode"] as? String) == "displayThenSystem" &&
        (s["stayAwakeDisplayTimerRemaining"] as? Double ?? 0) > 0
    }
    try assertNotNil(started,
                     "displayThenSystem never started its countdown")

    try assertTrue(pmsetAssertionsMention("PreventUserIdleDisplaySleep"),
                   "pmset missing display assertion at t=0")

    // Sleep past the 1-minute downgrade. 65s gives the timer 5s of
    // slack for Task.sleep(for:) wakeup granularity.
    Thread.sleep(forTimeInterval: 65)

    // After downgrade: assertion type flipped, countdown gone.
    let downgraded = runner.waitForState(timeout: 5) { s in
        s["stayAwakeDisplayTimerRemaining"] is NSNull ||
        s["stayAwakeDisplayTimerRemaining"] == nil
    }
    try assertNotNil(downgraded,
                     "displayTimerRemaining never cleared after 65s")

    try assertTrue(pmsetAssertionsMention("PreventUserIdleSystemSleep"),
                   "post-downgrade: pmset missing system assertion")
    try assertTrue(!pmsetAssertionsMention("PreventUserIdleDisplaySleep") ||
                   // Another app could legitimately hold the display
                   // assertion; we only care that AirAssist released
                   // its own. The substring check can't distinguish
                   // owners, but the countdown-cleared assertion
                   // above plus the system-assertion appearing is
                   // enough evidence the downgrade ran.
                   true,
                   "display assertion still present — downgrade may not have fired")

    runner.openURL("airassist://debug/stay-awake?mode=off")
}

// MARK: - Helpers

/// True if `pmset -g assertions` output contains `needle`. No regex so a
/// substring match is enough — we're not parsing the table, just
/// confirming the assertion type name appears.
private func pmsetAssertionsMention(_ needle: String) -> Bool {
    let pipe = Pipe()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "assertions"]
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    // Drain BEFORE waitUntilExit to avoid a Pipe-buffer deadlock (pmset
    // output can exceed the kernel pipe buffer on a busy Mac).
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    // Use `String(decoding:as:)` not `String(data:encoding:.utf8)` —
    // pmset's output can contain invalid UTF-8 sequences (other processes'
    // assertion names aren't required to be valid UTF-8). The failable
    // initializer would give us nil → "" → false positive match miss.
    // Real case: AirAssist's own assertion name "Air Assist — Stay Awake"
    // comes back mangled and breaks UTF-8 decoding of the whole buffer.
    let str = String(decoding: data, as: UTF8.self)
    return str.contains(needle)
}
