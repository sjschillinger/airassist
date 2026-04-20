# AirAssistIntegrationTests

Runtime-safety integration suite — automated equivalents of the shell
runbooks under `scripts/manual-tests/`. These tests launch the just-built
`AirAssist.app` out-of-process and drive it via the `airassist://` URL
scheme (including the `airassist://debug/*` endpoints that are only
compiled in under DEBUG — see `AirAssist/Services/URLSchemeHandler+Debug.swift`).

## What's covered

| Test                                       | Covers | What it proves                                                   |
| ------------------------------------------ | ------ | ---------------------------------------------------------------- |
| `ThrottleIntegrationTests.test_16_…`       | #16    | SIGSTOP actually lands on throttled PIDs (ps state "T")          |
| `ThrottleIntegrationTests.test_17_…`       | #17    | Dead-man's-switch SIGCONTs orphans on next launch                |
| `ThrottleIntegrationTests.test_19_…`       | #19    | kqueue exit-watcher releases the throttler before PID reuse      |
| `ThrottleIntegrationTests.test_34_…`       | #34    | Rules persist and re-attach on relaunch                          |
| `ThrottleIntegrationTests.test_38_…`       | #38    | SIGTERM handler SIGCONTs every in-flight PID before exit         |
| `PauseAndStayAwakeTests.test_35_…`         | #35    | `airassist://pause?duration=2s` auto-resumes after 2s            |
| `PauseAndStayAwakeTests.test_36_…`         | #36    | Stay-Awake modes register/release real `IOPMAssertion`s          |

## Why out-of-process

The tests do **not** inject into AirAssist (no `BUNDLE_LOADER`/`TEST_HOST` in
`project.yml`). Injecting a test dylib into the app would distort the signal
delivery semantics that #16/#17/#19/#38 are precisely trying to verify. Out
of process, SIGTERM really runs the installed `sigaction` handler; SIGKILL
really leaves orphaned `SIGSTOP`ed PIDs for the dead-man's-switch to recover.

## Running

```
xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
  -configuration Debug \
  -only-testing:AirAssistIntegrationTests test
```

First-time setup:

1. **LaunchServices registration**: the first run registers the Debug build's
   `airassist://` claim with macOS. If you also have `/Applications/AirAssist.app`
   installed, LaunchServices may route URLs to that copy instead of the test
   build. Delete the Applications copy or run
   `lsregister -u /Applications/AirAssist.app` before the suite.
2. **First-run modals**: `AirAssistRunner.launch()` writes
   `firstRunDisclosure.seenVersion` and `onboarding.seenVersion` to 999 via
   `defaults write com.sjschillinger.airassist` so the disclosure/onboarding
   `NSAlert.runModal()` calls don't block the URL-scheme handler.

If `waitForPing` times out on a fresh machine, it's almost always one of
those two — the app is running but URLs are going somewhere else, or the
main thread is blocked on a modal.

## Adding a new test

The `AirAssistRunner` API is intentionally small:

```swift
let runner = try AirAssistRunner()
try runner.launch()                          // clean slate, rules cleared
runner.seedExecutableRule(name: "yes",       // keyed by exec name
                          duty: 0.1)
let proc = try runner.spawnYesTarget()
let state = runner.waitForState(timeout: 5) { s in
    ((s["throttledProcesses"] as? [[String: Any]]) ?? [])
        .contains { ($0["pid"] as? Int) == Int(proc.processIdentifier) }
}
XCTAssertNotNil(state)
runner.tearDown()
```

Anything that needs a new debug-only probe goes in
`AirAssist/Services/URLSchemeHandler+Debug.swift` (wrapped in `#if DEBUG`
so Release builds never expose it), not here.
