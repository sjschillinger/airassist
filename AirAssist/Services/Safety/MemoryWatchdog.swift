import Foundation
import Darwin
import os

/// Periodic RSS tripwire (#49 follow-up).
///
/// Leaks analysis (2026-04-19) established that AirAssist's only observable
/// leak source is an Apple `NSHostingView` / CGRegion framework bug that
/// leaks ~96 bytes per window-layout event — on the order of a few hundred
/// bytes/hour under realistic use. That's invisible in practice, but we
/// want a cheap belt-and-suspenders breadcrumb in case:
///
///   1. A future macOS regression amplifies the per-event cost, or
///   2. We inadvertently introduce an AirAssist-side leak later.
///
/// This service samples the process's resident set size every 5 minutes
/// using `mach_task_basic_info` and emits a single os_log warning if RSS
/// crosses `Self.rssThresholdMB`. Log-only — no telemetry, no UI, no
/// automatic remediation. The warning is intended to surface in
/// `log show --predicate 'subsystem == "com.sjschillinger.airassist"'`
/// when a user reports something anomalous.
///
/// Cost per tick is a single `task_info` syscall (microseconds), so the
/// 5-minute interval is generous — could be shorter if needed.
@MainActor
final class MemoryWatchdog {
    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "memory")

    /// RSS ceiling in MB. A healthy AirAssist session sits around 30–50 MB
    /// (see #49 leaks-1hr-findings.md). 500 MB is ~10× that — comfortably
    /// above normal jitter, well below anything that would cause user-
    /// visible pressure on a modern Mac.
    static let rssThresholdMB: UInt64 = 500

    /// Sampling interval. 5 minutes is cheap and still catches a runaway
    /// leak within minutes rather than hours.
    static let sampleInterval: TimeInterval = 300

    private var timer: Timer?
    /// Once we've warned, don't spam the log every 5 minutes. Re-arm on
    /// process restart.
    private var hasWarned = false

    func start() {
        stop()
        // Fire once immediately so a cold-launch anomaly is logged without
        // waiting 5 minutes.
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = 30 // coalesce with other timers
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let rssBytes = Self.residentSetSize() else { return }
        let rssMB = rssBytes / 1024 / 1024
        logger.debug("RSS sample: \(rssMB, privacy: .public) MB")
        if rssMB > Self.rssThresholdMB && !hasWarned {
            logger.warning(
                "RSS tripwire: \(rssMB, privacy: .public) MB exceeds \(Self.rssThresholdMB, privacy: .public) MB threshold. File a bug with a diagnostic bundle if you see this."
            )
            hasWarned = true
        }
    }

    /// Current process resident set size in bytes, or nil if the syscall
    /// fails (it shouldn't under normal conditions).
    static func residentSetSize() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.resident_size
    }
}
