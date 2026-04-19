import Foundation

/// Entry point for the AirAssist integration-test CLI.
///
/// Why a CLI instead of `xcodebuild test`: xcodebuild's test infrastructure
/// insists on hosting the test bundle inside an app bundle (either the
/// AUT's PlugIns for unit tests, or XCTRunner.app for UI tests). Both
/// route signal delivery through the same process that's running the
/// tests — fatal for a suite whose whole purpose is SIGKILL-ing the
/// process under test. A plain `tool` target produces a normal macOS
/// executable; `scripts/run-integration.sh` builds AirAssist.app and this
/// runner together, then invokes the runner directly. The runner spawns
/// AirAssist as a child, so SIGKILL tests land on the child, not us.
///
/// Usage:
///   AirAssistIntegrationRunner                # run all tests
///   AirAssistIntegrationRunner test_16_SIGSTOPLands   # run one test by name
///   AirAssistIntegrationRunner --list         # print registered tests
///
/// Exit codes: 0 if all requested tests passed, 1 if any failed.

typealias TestFn = (AirAssistRunner) throws -> Void

/// Every test is registered here. Ordering matters only for readability;
/// each test sets up its own runner, so they're independent.
let allTests: [(String, TestFn)] = [
    // #16/#17/#19/#34/#38 — throttle + signal delivery
    ("test_16_SIGSTOPLands",                 test_16_SIGSTOPLands),
    ("test_17_CrashRecoveryResumesOrphaned", test_17_CrashRecoveryResumesOrphaned),
    ("test_19_ExitWatcherReleasesPromptly",  test_19_ExitWatcherReleasesPromptly),
    ("test_34_RuleReattachAfterRelaunch",    test_34_RuleReattachAfterRelaunch),
    ("test_38_SIGTERMResumesInflight",       test_38_SIGTERMResumesInflight),
    // #35/#36 — pause + stay-awake
    ("test_35_PauseAutoResumes",                     test_35_PauseAutoResumes),
    ("test_35_ExplicitResumeClearsPause",            test_35_ExplicitResumeClearsPause),
    ("test_36_StayAwakeSystemAssertionRegistersWithPMSet",
        test_36_StayAwakeSystemAssertionRegistersWithPMSet),
    ("test_36_StayAwakeDisplayAssertion",            test_36_StayAwakeDisplayAssertion),
]

// MARK: - Arg parsing

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--list") || args.contains("-l") {
    for (name, _) in allTests { print(name) }
    exit(0)
}

let selected: [(String, TestFn)]
if args.isEmpty {
    selected = allTests
} else {
    let requested = Set(args)
    selected = allTests.filter { requested.contains($0.0) }
    let missing = requested.subtracting(selected.map { $0.0 })
    if !missing.isEmpty {
        FileHandle.standardError.write(Data("unknown test(s): \(missing.sorted().joined(separator: ", "))\n".utf8))
        exit(2)
    }
}

// MARK: - Run

// Each test gets a fresh runner. Setup/teardown mirror what
// XCTestCase.setUpWithError / tearDownWithError used to do. We catch all
// errors so one failure doesn't abort the run — the exit code at the end
// reflects the aggregate.

var passed: [String] = []
var failed: [(String, String)] = []
let overallStart = Date()

for (name, fn) in selected {
    let start = Date()
    print("\n▶ \(name)")
    do {
        let runner = try AirAssistRunner()
        try runner.launch()

        // Stay-Awake tests need an off-reset even if they fail midway, so
        // the IOPMAssertion doesn't leak into the next test.
        defer {
            if name.hasPrefix("test_36_") {
                runner.openURL("airassist://debug/stay-awake?mode=off")
            }
            runner.tearDown()
        }

        try fn(runner)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("  ✓ PASS (\(ms)ms)")
        passed.append(name)
    } catch let err as AssertionError {
        print("  ✗ FAIL — \(err.description)")
        failed.append((name, err.description))
    } catch {
        print("  ✗ ERROR — \(error)")
        failed.append((name, String(describing: error)))
    }
}

// MARK: - Summary

let totalMs = Int(Date().timeIntervalSince(overallStart) * 1000)
print("\n=======================================")
print("PASSED: \(passed.count)")
print("FAILED: \(failed.count)")
print("TOTAL:  \(selected.count)  (\(totalMs)ms)")
print("=======================================")
for (name, reason) in failed {
    print("  - \(name): \(reason)")
}

exit(failed.isEmpty ? 0 : 1)
