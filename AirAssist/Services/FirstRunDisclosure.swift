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

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Welcome to Air Assist"
        alert.informativeText = """
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
        alert.addButton(withTitle: "I Understand")
        alert.addButton(withTitle: "View License")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html") {
                NSWorkspace.shared.open(url)
            }
        }

        UserDefaults.standard.set(currentVersion, forKey: seenKey)
    }
}
