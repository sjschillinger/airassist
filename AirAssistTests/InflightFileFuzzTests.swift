import XCTest
import Darwin
@testable import AirAssist

/// Fuzz-style tests for `SafetyCoordinator.recoverOnLaunch`. The dead-man's-
/// switch file lives in `~/Library/Application Support/AirAssist/inflight.json`
/// and is read on every cold launch — corruption from a bad disk, an
/// interrupted write during a kernel panic, or a mis-versioned decoder must
/// never prevent the app from launching.
///
/// For each garbage variant we assert two invariants:
///   1. `recoverOnLaunch()` completes without crashing (can't throw — the
///      method is `throws`-free by design, so the test just has to not
///      explode).
///   2. The inflight file is removed afterwards, so the next launch starts
///      from a clean slate rather than re-reading the same garbage forever.
@MainActor
final class InflightFileFuzzTests: XCTestCase {

    private var url: URL { SafetyCoordinator.inflightFileURL }

    override func setUp() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeRaw(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func assertFileRemovedAfterRecovery(_ label: String) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "\(label): recoverOnLaunch must remove the inflight file so bad " +
            "contents can't re-poison subsequent launches"
        )
    }

    // MARK: - Structural corruption

    func testEmptyFileIsTolerated() throws {
        try writeRaw(Data())
        SafetyCoordinator.recoverOnLaunch()
        assertFileRemovedAfterRecovery("empty")
    }

    func testNonJSONGarbageIsTolerated() throws {
        try writeRaw(Data(repeating: 0xFF, count: 128))
        SafetyCoordinator.recoverOnLaunch()
        assertFileRemovedAfterRecovery("binary garbage")
    }

    func testTruncatedJSONIsTolerated() throws {
        try writeRaw(Data(#"{"pids":[42,43,"#.utf8))
        SafetyCoordinator.recoverOnLaunch()
        assertFileRemovedAfterRecovery("truncated JSON")
    }

    func testUnrelatedJSONShapeIsTolerated() throws {
        try writeRaw(Data(#"{"unrelated":"shape","version":99}"#.utf8))
        SafetyCoordinator.recoverOnLaunch()
        assertFileRemovedAfterRecovery("unrelated JSON")
    }

    // MARK: - Semantically wrong values

    func testPIDsOfWrongTypeAreTolerated() throws {
        // pids should be an array of Int, not strings.
        try writeRaw(Data(#"{"pids":["abc","def"],"writtenAt":0}"#.utf8))
        SafetyCoordinator.recoverOnLaunch()
        assertFileRemovedAfterRecovery("wrong-type pids")
    }

    func testAbsurdPIDsAreSkipped() throws {
        // pid 0 / negative / enormous values must not be forwarded to kill().
        // We can't easily observe that kill wasn't called, but we can assert
        // the method completes and removes the file. The pid range guard
        // `raw > 1 && raw < 1_000_000` is what keeps this from SIGSEGV'ing
        // in the signal layer or invoking kill on sentinel values.
        let json = #"{"pids":[0,-1,1,999999999],"writtenAt":[748339200,0]}"#
        try writeRaw(Data(json.utf8))
        SafetyCoordinator.recoverOnLaunch()
        assertFileRemovedAfterRecovery("absurd pids")
    }

    func testPIDOneIsSkipped() throws {
        // pid 1 is launchd. Even if some corruption wrote it, kill(1, SIGCONT)
        // from a user process is EPERM — but more importantly the recovery
        // logic must never be allowed to target init.
        try writeRaw(Data(#"{"pids":[1],"writtenAt":[748339200,0]}"#.utf8))
        SafetyCoordinator.recoverOnLaunch()
        assertFileRemovedAfterRecovery("pid 1")
    }

    // MARK: - Missing-file path

    func testNoFileIsANoOp() {
        // Pre-condition: setUp removed the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        SafetyCoordinator.recoverOnLaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "recoverOnLaunch must not create the file when absent")
    }

    // MARK: - Round-trip safety

    /// A write followed by a recover round-trip on a live pid (our own
    /// test process) should not crash, should remove the file, and should
    /// leave us alive. This validates the happy path in the same harness.
    func testWriteThenRecoverRoundTrip() {
        // Writing our own pid is safe: we're alive, so SIGCONT is a no-op.
        // We'd never do this in production (the throttler refuses to touch
        // its own pid), but it's the cleanest way to test the write/recover
        // pair without spawning a child.
        let me = getpid()
        SafetyCoordinator.writeInflight(pids: [me])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "writeInflight with non-empty pids should create the file")

        SafetyCoordinator.recoverOnLaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "recoverOnLaunch must remove the file after a successful recovery")
        // If we're still executing, we weren't killed by the SIGCONT — good.
    }

    /// writeInflight with an empty list must delete the file rather than
    /// writing an empty record. Otherwise the file grows stale entries over
    /// time as sources come and go.
    func testWriteInflightEmptyDeletesFile() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("{}".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        SafetyCoordinator.writeInflight(pids: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "writeInflight([]) should delete the file")
    }
}
