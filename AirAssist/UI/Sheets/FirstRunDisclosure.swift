import AppKit

/// One-time legal/safety disclosure shown on first launch.
///
/// The governor is off by default (see `FirstLaunchSeeder`), so the app does
/// nothing to user processes unless explicitly enabled. This alert exists so
/// no one can credibly say they weren't told what the app *can* do once armed.
///
/// Idempotent: keyed by `seenVersion`. Bump `currentVersion` if the disclosure
/// text materially changes (new capability, new risk) and you want to
/// re-prompt existing users.
@MainActor
enum FirstRunDisclosure {
    private static let seenKey = "firstRunDisclosure.seenVersion"
    private static let currentVersion = 1

    static func presentIfNeeded() {
        let seen = UserDefaults.standard.integer(forKey: seenKey)
        guard seen < currentVersion else { return }

        // Non-modal floating window (see InfoSheetWindow) — replaced the
        // previous `NSAlert.runModal()` because that ran the runloop in
        // `.modalPanel` mode and starved `application(_:open:)` of Apple
        // Events, so a Shortcut/`open airassist://...` that *triggered*
        // the cold launch would sit queued until the user dismissed.
        let body = """
        Air Assist monitors your Mac's thermal sensors and, when you enable \
        the governor, can pause and resume processes you own by sending \
        SIGSTOP and SIGCONT signals. This is a standard Unix technique — \
        but pausing the wrong process at the wrong time can stall an app, \
        drop a network connection, or in rare cases lose unsaved work.

        The governor is OFF by default. You control when (and on which \
        processes) throttling runs.

        Air Assist is provided AS IS, without warranty of any kind, under \
        the GNU AGPL v3. You use it at your own risk.

        Not affiliated with Apple Inc.
        """
        InfoSheetWindow.present(
            title: "Welcome to Air Assist",
            body: body,
            primaryButton: "I Understand",
            secondaryButton: "View License",
            secondaryAction: {
                if let url = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html") {
                    NSWorkspace.shared.open(url)
                }
            },
            onClose: {
                UserDefaults.standard.set(currentVersion, forKey: seenKey)
            }
        )
    }
}
