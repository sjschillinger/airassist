import XCTest
import Darwin
@testable import AirAssist

@MainActor
final class SafetyCoordinatorTests: XCTestCase {

    override func setUp() async throws {
        // Ensure no stale inflight file from a previous test run.
        try? FileManager.default.removeItem(at: SafetyCoordinator.inflightFileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: SafetyCoordinator.inflightFileURL)
    }

    // MARK: - Ancestor / self protection

    func testIsAncestorOrSelfForOwnPIDReturnsTrue() {
        XCTAssertTrue(SafetyCoordinator.isAncestorOrSelf(pid: getpid()))
    }

    func testIsAncestorOrSelfForInitReturnsTrue() {
        XCTAssertTrue(SafetyCoordinator.isAncestorOrSelf(pid: 1))
    }

    func testIsAncestorOrSelfForZeroReturnsTrue() {
        XCTAssertTrue(SafetyCoordinator.isAncestorOrSelf(pid: 0))
    }

    func testIsAncestorOrSelfForParentReturnsTrue() {
        // getppid() is always an ancestor.
        XCTAssertTrue(SafetyCoordinator.isAncestorOrSelf(pid: getppid()))
    }

    // MARK: - Dead-man's-switch round-trip

    func testWriteInflightThenRecoverRemovesFile() {
        // Use PIDs that don't exist (very high numbers) — kill() will ESRCH,
        // which is harmless. We just want the file round-trip.
        let fakePIDs: [pid_t] = [999990, 999991, 999992]
        SafetyCoordinator.writeInflight(pids: fakePIDs)

        XCTAssertTrue(FileManager.default.fileExists(atPath: SafetyCoordinator.inflightFileURL.path),
                      "inflight file should exist after writeInflight")

        SafetyCoordinator.recoverOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: SafetyCoordinator.inflightFileURL.path),
                       "inflight file should be removed after recoverOnLaunch")
    }

    func testWriteInflightEmptyRemovesFile() {
        SafetyCoordinator.writeInflight(pids: [pid_t(999990)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: SafetyCoordinator.inflightFileURL.path))

        SafetyCoordinator.writeInflight(pids: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: SafetyCoordinator.inflightFileURL.path))
    }

    func testRecoverOnLaunchHandlesMissingFile() {
        // Should not crash when there's no inflight file.
        try? FileManager.default.removeItem(at: SafetyCoordinator.inflightFileURL)
        SafetyCoordinator.recoverOnLaunch()
    }
}
