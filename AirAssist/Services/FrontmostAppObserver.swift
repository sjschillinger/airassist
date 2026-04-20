import AppKit

/// Tracks which app is currently frontmost so the throttler can soften
/// or skip throttling on it — nothing is more jarring than finding the
/// window you're actively typing in SIGSTOP'd mid-keystroke.
///
/// Publishes the frontmost PID to a callback. ThermalStore wires it to
/// `ProcessThrottler.setForegroundPID` on changes.
@MainActor
final class FrontmostAppObserver {
    private var observer: Any?
    private let onChange: (pid_t?) -> Void

    init(onChange: @escaping (pid_t?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        // Seed with the current frontmost app so the throttler has a value
        // before the first notification fires.
        let initial = NSWorkspace.shared.frontmostApplication?.processIdentifier
        onChange(initial)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                self?.onChange(pid)
            }
        }
    }

    func stop() {
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            observer = nil
        }
    }
}
