import AppKit
import os

/// A SIGCONT we attempted (typically on `release(pid:)` or shutdown) failed
/// with a non-ESRCH error after every retry. This is rare but catastrophic:
/// the user's process is frozen and we could not un-freeze it. The right
/// default is not to hide it — tell the user something is stuck, tell them
/// how to fix it manually, and log the details so a diagnostic bundle
/// captures the context.
///
/// Possible causes include:
///   * TCC / sandbox regression revoked our signal entitlement mid-session.
///   * A macOS update changed privilege requirements for signalling that pid.
///   * The pid migrated to a different user (`su`, `sudo`) since we started
///     throttling it — EPERM is expected.
///
/// We coalesce bursts: if we already showed an alert in the last 5 seconds,
/// the next failure just logs. Alert spam is worse than silence.
@MainActor
enum SIGCONTFailureAlert {
    private static let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                       category: "SIGCONTFailure")
    private static var lastAlertAt: Date?
    private static let coalesceWindow: TimeInterval = 5.0

    static func report(pid: pid_t, name: String, errno errnoValue: Int32) {
        let errName = errnoString(errnoValue)
        logger.error("""
        SIGCONT pid=\(pid, privacy: .public) name=\(name, privacy: .public) \
        failed after retry: errno=\(errnoValue) (\(errName, privacy: .public))
        """)

        let now = Date()
        if let last = lastAlertAt, now.timeIntervalSince(last) < coalesceWindow {
            return
        }
        lastAlertAt = now

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't resume a paused process"
        alert.informativeText = """
        Air Assist tried to release \(name) (PID \(pid)) but the system \
        rejected the signal (\(errName)).

        If this process is hung, open Activity Monitor, select it, and choose \
        View → Send Signal to Process → Continue (SIGCONT).
        """
        alert.addButton(withTitle: "Open Activity Monitor")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private static func errnoString(_ e: Int32) -> String {
        switch e {
        case EPERM:  return "EPERM — operation not permitted"
        case ESRCH:  return "ESRCH — no such process"
        case EINVAL: return "EINVAL — invalid signal"
        default:     return "errno \(e)"
        }
    }
}
