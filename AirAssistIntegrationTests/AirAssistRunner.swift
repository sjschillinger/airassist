import Foundation

/// Out-of-process harness for the runtime-safety integration tests.
///
/// Packaged as a command-line tool (target `AirAssistIntegrationRunner`),
/// NOT an xctest bundle. We fought xcodebuild test infrastructure for a
/// day trying to get truly out-of-process signal-delivery testing: every
/// variant (`bundle.unit-test` with/without TEST_HOST, `bundle.ui-testing`)
/// either injected the test code into AirAssist.app (so SIGKILL-tests
/// killed the harness) or required Accessibility/automation TCC grants
/// we can't script. A plain `tool` target sidesteps the whole stack —
/// `xcodebuild build` produces both AirAssist.app and the test runner,
/// then `scripts/run-integration.sh` invokes the runner directly. The
/// runner is a normal Foundation-only process that spawns AirAssist as
/// a child.
///
/// Each test launches the just-built `AirAssist.app` as a child process
/// and communicates via:
///
///   • The `airassist://` URL scheme (including the `debug/*` endpoints
///     that are compiled in only under DEBUG — see
///     `URLSchemeHandler+Debug.swift`).
///   • A tmp-dir JSON state file written by `debug/export-state` and
///     read back by the test.
///
/// The tests must tolerate the shared system state AirAssist reaches
/// into (UserDefaults, NSWorkspace notifications, pmset assertions).
/// Each test uses `AirAssistRunner` which:
///
///   1. Backs up the user's existing rules config so a run on a real
///      developer machine doesn't clobber their rules.
///   2. Clears rules before launch.
///   3. Points AirAssist at the built-in-product-dir binary, not any
///      /Applications install — avoids a collision with the user's
///      normal install.
///   4. Cleans up every spawned target and restores backups on deinit.
///
/// The harness is deliberately shell-heavy (pgrep, open, ps) — those
/// are the primitives we need and reimplementing them in Foundation
/// adds no value.
final class AirAssistRunner {

    /// Where debug-state dumps and ping responses go.
    let workingDir: URL

    /// PID of the launched AirAssist process, once it's running.
    private(set) var pid: Int32?

    /// Full path to the app bundle under test.
    let appBundleURL: URL

    /// Tracks spawned /bin/sh-based target processes so teardown can
    /// SIGCONT-then-SIGTERM them all, avoiding stranded `yes` loops.
    private var spawnedTargets: [Process] = []

    /// Rules-config UserDefaults key (mirrors ThrottleRulesPersistence).
    private static let rulesDefaultsKey = "throttleRules.v1"

    /// Snapshot of whatever the user had in the rules defaults before we
    /// started poking at them. Restored on `tearDown()`.
    private var savedRulesBlob: Data?

    init() throws {
        // Locate AirAssist.app. As a CLI tool target, the runner
        // binary sits in BUILT_PRODUCTS_DIR (e.g.
        // .../Build/Products/Debug/AirAssistIntegrationRunner) and
        // AirAssist.app is its sibling there. We walk up from the
        // executable path, not from Bundle.main which is unreliable
        // for command-line tools.
        let exePath = CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let productsDir = exePath.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates: [URL] = [
            productsDir.appendingPathComponent("AirAssist.app"),
            // Also honor an explicit override via env for CI / manual use.
            ProcessInfo.processInfo.environment["AIRASSIST_APP"]
                .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/dev/null"),
        ]
        let found = candidates.first { url in
            url.pathExtension == "app" && FileManager.default.fileExists(atPath: url.path)
        }
        guard let candidate = found else {
            FileHandle.standardError.write(Data("AirAssist.app not found. Looked in: \(candidates.map(\.path))\n".utf8))
            throw RunnerError.appNotBuilt
        }
        self.appBundleURL = candidate

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("airassist-integration-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workingDir = dir
    }

    enum RunnerError: Error {
        case appNotBuilt
        case launchFailed(String)
        case pingTimeout
        case stateParseFailed
    }

    // MARK: - Lifecycle

    /// Start AirAssist, wait for it to respond on the URL scheme, clear
    /// rules, and return. Idempotent — kills any existing AirAssist first.
    func launch(timeout: TimeInterval = 15) throws {
        trace("launch: start appBundleURL=\(appBundleURL.path)")
        backupRulesDefaults()
        trace("launch: backup done, killing any running AirAssist")
        killAnyRunningAirAssist()
        trace("launch: kill done, suppressing first-run modals")
        // Suppress the first-run disclosure and onboarding modals — both
        // are NSAlert.runModal() which blocks the main thread and wedges
        // the URL-scheme handler. The integration suite assumes a headless
        // AirAssist. Stamp the "seen" keys to a future version so they
        // never fire.
        suppressFirstRunModals()
        trace("launch: running open -g -n -a \(appBundleURL.path)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g prevents activation stealing focus, -n forces a new instance
        // in case LaunchServices still thinks one is alive.
        proc.arguments = ["-g", "-n", "-a", appBundleURL.path]
        try proc.run()
        proc.waitUntilExit()
        trace("launch: open exited status=\(proc.terminationStatus)")
        guard proc.terminationStatus == 0 else {
            throw RunnerError.launchFailed("open returned \(proc.terminationStatus)")
        }

        // Poll for the process to appear by bundle-path match.
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        while Date() < deadline {
            if let p = pgrepAirAssist() {
                self.pid = p
                trace("launch: pgrep found pid=\(p) after \(polls) polls")
                break
            }
            polls += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard pid != nil else {
            trace("launch: pgrep never found AirAssist after \(timeout)s")
            captureHangDiagnostic(reason: "AirAssist never appeared in pgrep after \(timeout)s")
            throw RunnerError.launchFailed("AirAssist never appeared in pgrep after \(timeout)s")
        }

        // URL scheme is registered during applicationDidFinishLaunching.
        // Ping until we get a pong file back so tests never race an
        // uninitialized store.
        trace("launch: waiting for ping")
        try waitForPing(timeout: timeout)
        trace("launch: ping ok, clearing rules")

        // Fresh slate: no rules, engine off.
        openURL("airassist://debug/clear-rules")
        trace("launch: done")
    }

    /// Emit a line to stderr AND a persistent log file so we can trace
    /// where a hang happened without needing the xcresult bundle.
    /// Writes to /tmp/airassist-integration-trace.log (appended, survives
    /// tearDown) and fputs to stderr (appears inline in xcodebuild output).
    private func trace(_ msg: String) {
        let line = "[AirAssistRunner \(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        fputs(line, stderr)
        if let fh = FileHandle(forWritingAtPath: "/tmp/airassist-integration-trace.log") {
            fh.seekToEndOfFile()
            if let d = line.data(using: .utf8) { fh.write(d) }
            try? fh.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/airassist-integration-trace.log"))
        }
    }

    /// Clean shutdown. Sends SIGTERM (the graceful path; SafetyCoordinator
    /// handlers run and all throttled PIDs are SIGCONT'd).
    func terminateGracefully(timeout: TimeInterval = 5) {
        guard let p = pid else { return }
        kill(p, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, pgrepAirAssist() != nil {
            Thread.sleep(forTimeInterval: 0.1)
        }
        self.pid = nil
    }

    /// Hard kill. Simulates a crash: signal handlers do NOT run. The
    /// dead-man's-switch file is what should bring things back on the
    /// next launch.
    func killHard() {
        guard let p = pid else { return }
        kill(p, SIGKILL)
        while pgrepAirAssist() != nil { Thread.sleep(forTimeInterval: 0.1) }
        self.pid = nil
    }

    /// Tear everything down: kill spawned targets, SIGCONT anything we
    /// paused, terminate AirAssist, restore rules backup. Safe to call
    /// multiple times.
    func tearDown() {
        for t in spawnedTargets where t.isRunning {
            kill(t.processIdentifier, SIGCONT) // defensively resume
            t.terminate()
            t.waitUntilExit()
        }
        spawnedTargets.removeAll()
        terminateGracefully()
        restoreRulesDefaults()
        try? FileManager.default.removeItem(at: workingDir)
    }

    // MARK: - URL scheme

    /// Fire-and-forget — the URL scheme returns no status. Use
    /// `exportState()` after to verify effect.
    func openURL(_ str: String) {
        guard let url = URL(string: str) else {
            FileHandle.standardError.write(Data("Bad URL: \(str)\n".utf8)); return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-g`: background; don't steal focus every call.
        proc.arguments = ["-g", url.absoluteString]
        // `open` also accepts URLs positionally; quoting handled by Process.
        _ = try? proc.run()
        proc.waitUntilExit()
    }

    /// Blocks until AirAssist writes a pong file, or throws on timeout.
    /// On timeout, writes a `sample(1)` stack trace of the AirAssist process
    /// and the last 30s of its `os_log` output into `workingDir/diagnostic/`
    /// — future hangs self-diagnose instead of requiring interactive debugging.
    private func waitForPing(timeout: TimeInterval) throws {
        let pongPath = workingDir.appendingPathComponent("pong.txt").path
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? FileManager.default.removeItem(atPath: pongPath)
            openURL("airassist://debug/ping?to=\(pongPath.urlEncoded)")
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.1)
                if FileManager.default.fileExists(atPath: pongPath) { return }
            }
        }
        captureHangDiagnostic(reason: "waitForPing timed out after \(timeout)s")
        throw RunnerError.pingTimeout
    }

    /// Snapshot everything we'd want if the suite hangs in CI: `sample`
    /// stack of AirAssist, last 30s of its os_log, `ps` of our subtree.
    /// Writes to `/tmp/airassist-integration-diagnostic-<UUID>.txt` and
    /// prints the path to stderr so the run log surfaces it.
    func captureHangDiagnostic(reason: String) {
        // Write to /tmp (NOT workingDir) so it survives tearDown's
        // removeItem of the working dir. Test Report shows the path.
        let path = "/tmp/airassist-integration-diagnostic-\(UUID().uuidString).txt"
        var out = "=== AirAssist integration hang diagnostic ===\n"
        out += "reason: \(reason)\n"
        out += "time:   \(ISO8601DateFormatter().string(from: Date()))\n\n"

        if let p = pgrepAirAssist() ?? self.pid {
            out += "--- sample(AirAssist pid=\(p), 1s) ---\n"
            out += shell("/usr/bin/sample", ["\(p)", "1"]) + "\n\n"
            out += "--- ps for pid=\(p) ---\n"
            out += shell("/bin/ps", ["-o", "pid=,stat=,etime=,command=", "-p", "\(p)"]) + "\n\n"
        } else {
            out += "(no AirAssist process to sample)\n\n"
        }
        out += "--- log show airassist subsystem (last 30s) ---\n"
        out += shell("/usr/bin/log", [
            "show",
            "--predicate", "subsystem == \"com.sjschillinger.airassist\"",
            "--last", "30s",
            "--info",
        ]) + "\n"
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("AirAssist hung — diagnostic at \(path)\n".utf8))
    }

    /// One-shot shell capture. Used only by the diagnostic path so it's
    /// fine to block; never on the hot path.
    private func shell(_ tool: String, _ args: [String]) -> String {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "(failed to run \(tool))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Seed rules

    func seedRule(bundle: String, duty: Double, enabled: Bool = true) {
        let dutyStr = String(format: "%.2f", duty)
        let b = bundle.urlEncoded
        openURL("airassist://debug/seed-rule?bundle=\(b)&duty=\(dutyStr)&enabled=\(enabled)")
    }

    /// Rule keyed by executable name instead of bundle ID. Required for
    /// targets without an Info.plist (shell-spawned `yes`, etc.) — the
    /// rule engine keys such processes as `name:<exec>`.
    func seedExecutableRule(name: String, duty: Double, enabled: Bool = true) {
        let dutyStr = String(format: "%.2f", duty)
        let n = name.urlEncoded
        openURL("airassist://debug/seed-rule?bundle=\(n)&duty=\(dutyStr)&enabled=\(enabled)&keyType=name")
    }

    // MARK: - State export

    /// One-shot snapshot via `debug/export-state`. Returns nil on read
    /// failure; XCTestCase helpers wrap this with retries.
    func exportState() -> [String: Any]? {
        let path = workingDir
            .appendingPathComponent("state-\(UUID().uuidString).json").path
        openURL("airassist://debug/export-state?to=\(path.urlEncoded)")
        // Handler writes synchronously on main actor — but `open` is
        // async from our perspective, so poll briefly.
        for _ in 0..<30 {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? FileManager.default.removeItem(atPath: path)
                return obj
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Polls `exportState` until `predicate(state)` returns true or the
    /// deadline passes. Returns the last successfully-read state for the
    /// caller to assert against on failure.
    @discardableResult
    func waitForState(timeout: TimeInterval = 5,
                      where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any]?
        while Date() < deadline {
            if let s = exportState() {
                last = s
                if predicate(s) { return s }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return last
    }

    // MARK: - Spawned test targets

    /// Spawn `/usr/bin/yes >/dev/null` directly (no shell wrapper, so the
    /// returned `processIdentifier` is the `yes` PID itself — what the
    /// throttler will be driving). Running flat-out, this is a reliable
    /// throttle target.
    @discardableResult
    func spawnYesTarget() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        spawnedTargets.append(p)
        return p
    }

    // MARK: - Defaults backup

    /// Use `defaults write` (CFPreferences) so the keys land in AirAssist's
    /// own bundle-id domain, which is different from this test bundle's.
    /// `UserDefaults(suiteName:)` from the test process writes to the test
    /// domain, not the target — hence the shell-out.
    private func suppressFirstRunModals() {
        let pairs: [(String, String)] = [
            ("firstRunDisclosure.seenVersion", "999"),
            ("onboarding.seenVersion",         "999"),
        ]
        for (key, value) in pairs {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            p.arguments = ["write", "com.sjschillinger.airassist",
                           key, "-int", value]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            _ = try? p.run()
            p.waitUntilExit()
        }
    }

    private func backupRulesDefaults() {
        let d = UserDefaults(suiteName: "com.sjschillinger.airassist")
            ?? UserDefaults.standard
        savedRulesBlob = d.data(forKey: Self.rulesDefaultsKey)
    }

    private func restoreRulesDefaults() {
        let d = UserDefaults(suiteName: "com.sjschillinger.airassist")
            ?? UserDefaults.standard
        if let blob = savedRulesBlob {
            d.set(blob, forKey: Self.rulesDefaultsKey)
        } else {
            d.removeObject(forKey: Self.rulesDefaultsKey)
        }
    }

    // MARK: - pgrep / ps helpers

    /// Returns the PID of any running AirAssist whose executable path
    /// matches our built product dir exactly. Prevents clashing with a
    /// user's /Applications copy. We use `ps -Ao pid=,command=` here
    /// because macOS `pgrep -a` doesn't print the command line
    /// alongside the PID (the flag is FreeBSD-only).
    private func pgrepAirAssist() -> Int32? {
        let expected = appBundleURL
            .appendingPathComponent("Contents/MacOS/AirAssist").path
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pid=,command="]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // Drain pipe BEFORE waiting. `ps -A` output on a busy Mac easily
        // exceeds the 16-64KB Pipe buffer; if we wait first, ps blocks on
        // write and we deadlock. readDataToEndOfFile returns when ps
        // closes stdout (i.e., exits), so waitUntilExit below is a no-op.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in str.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.contains(expected) else { continue }
            // First whitespace-separated token is the pid.
            let parts = line.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true)
            if let pidStr = parts.first, let pid = Int32(pidStr) {
                return pid
            }
        }
        return nil
    }

    private func killAnyRunningAirAssist() {
        // Only kills our-built-products-dir copy, so a developer's
        // /Applications install isn't disturbed.
        while let p = pgrepAirAssist() {
            kill(p, SIGKILL)
            Thread.sleep(forTimeInterval: 0.1)
            if pgrepAirAssist() == p {
                // Didn't die — give up after a few tries to avoid infinite loop.
                Thread.sleep(forTimeInterval: 0.3)
                break
            }
        }
    }
}

private extension String {
    /// URL-encode for use as a query value or path segment.
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

/// Helper: returns the `ps -o stat=` single-char state for `pid`, or nil
/// if the process doesn't exist. "T" means stopped by SIGSTOP — the
/// smoking gun for throttle-landed.
func psState(for pid: Int32) -> String? {
    let pipe = Pipe()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "stat=", "-p", "\(pid)"]
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return s.isEmpty ? nil : s
}
