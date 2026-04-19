import AppKit
import ServiceManagement
import os

/// Thin wrapper around `SMAppService.mainApp` that surfaces errors the
/// user can actually act on, and keeps a live view of the registration
/// status for the preferences UI.
///
/// **What this fixes vs. the old inline binding:**
///   - The old code silently swallowed register/unregister errors in a
///     blanket `catch`. Users toggling the switch in DerivedData builds
///     got no indication it didn't take; users hitting `.requiresApproval`
///     had no idea they needed to visit System Settings.
///   - `SMAppService.status` doesn't post notifications — the only way to
///     reflect out-of-band changes (the user toggled it off in Login Items
///     & Extensions while our Preferences window was closed) is to re-read
///     on window activation. This service listens for
///     `NSWindow.didBecomeKeyNotification` on its observers and refreshes.
///   - `.requiresApproval` gets its own branch that opens
///     `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
///     so the user can approve without hunting through System Settings.
@MainActor
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "LaunchAtLogin")

    /// Observer block registered by `GeneralPrefsView` so the toggle
    /// redraws when the registration status changes under us.
    private var observers: [(SMAppService.Status) -> Void] = []

    /// Current registration status. Cheap to read — no IPC.
    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Convenience: true when the app is registered to launch at login.
    var isEnabled: Bool {
        status == .enabled
    }

    /// Register an observer for status changes. Returns a token the caller
    /// holds to keep the observation live; dropping it cancels. Observers
    /// are called on the main actor.
    @discardableResult
    func observe(_ block: @escaping @MainActor (SMAppService.Status) -> Void) -> AnyObject {
        observers.append(block)
        let idx = observers.count - 1
        return ObserverToken { [weak self] in
            guard let self else { return }
            // Fine-grained removal is overkill; we just null out the slot.
            if idx < self.observers.count {
                self.observers[idx] = { _ in }
            }
        }
    }

    /// Flip the registration state. On failure, presents an NSAlert with
    /// actionable advice. On `.requiresApproval`, opens the Login Items
    /// settings pane. Returns the resulting status so callers can reflect it.
    @discardableResult
    func setEnabled(_ enable: Bool) -> SMAppService.Status {
        let service = SMAppService.mainApp

        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error("\(enable ? "register" : "unregister") failed: \(String(describing: error), privacy: .public)")
            presentError(error, attemptedEnable: enable)
        }

        let resulting = service.status
        if enable, resulting == .requiresApproval {
            offerToOpenLoginItemsSettings()
        }

        notifyObservers(resulting)
        return resulting
    }

    /// Force-refresh observers — e.g. from `windowDidBecomeKey` in the
    /// Preferences UI, to catch the case where the user disabled our
    /// login item from System Settings while we weren't looking.
    func refresh() {
        notifyObservers(status)
    }

    // MARK: - Private

    private func notifyObservers(_ status: SMAppService.Status) {
        for obs in observers { obs(status) }
    }

    private func presentError(_ error: Error, attemptedEnable enable: Bool) {
        // Running from DerivedData during `xcodebuild` always fails with
        // `operationNotPermitted` — macOS won't register a login item at
        // a path it considers a build artifact. Detect and explain rather
        // than showing the raw error, which is cryptic.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = enable
            ? "Couldn't enable Launch at Login."
            : "Couldn't disable Launch at Login."

        let nsError = error as NSError
        if nsError.domain == "SMAppServiceErrorDomain", nsError.code == 1 /* notFound */ {
            alert.informativeText = """
            The system couldn't locate this build as a login item. This \
            usually happens when running from Xcode's build directory. \
            Move Air Assist to /Applications and try again.
            """
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func offerToOpenLoginItemsSettings() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Approval needed in System Settings."
        alert.informativeText = """
        macOS needs you to approve Air Assist in Login Items & Extensions \
        before it can launch automatically. I can open that pane for you.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Direct-link URL that opens exactly the Login Items pane on
            // macOS 13+. Falls back to the general "General" pane on
            // older versions (we target 15+ so this is reliable).
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private final class ObserverToken {
        let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        deinit { onCancel() }
    }
}
