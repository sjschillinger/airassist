import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    // nonisolated(unsafe) lets the synchronous entry point assign these before
    // the main actor is running; all actual use happens from @MainActor methods.
    nonisolated(unsafe) private var store: ThermalStore!
    nonisolated(unsafe) private var menuBarController: MenuBarController?

    nonisolated static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SAFETY: before we do *anything* else, recover from a previous
        // session that may have left processes SIGSTOPed. Then install
        // signal handlers so SIGTERM/SIGINT/SIGHUP/SIGQUIT always SIGCONT
        // our in-flight PIDs before exit.
        SafetyCoordinator.recoverOnLaunch()
        SafetyCoordinator.installSignalHandlers()

        store = ThermalStore()
        store.start()
        menuBarController = MenuBarController(store: store)

        // Global hotkey (#56). ⌘⌥P toggles pause/resume from anywhere.
        // Carbon-based — no Accessibility permission required.
        GlobalHotkeyService.shared.onTrigger = { [weak self] in
            guard let store = self?.store else { return }
            if store.isPauseActive {
                store.resumeThrottling()
            } else {
                store.pauseThrottling(for: nil) // indefinite until user resumes
            }
        }
        GlobalHotkeyService.shared.start()

        // One-time legal/safety disclosure. Runs after the menu bar is up so
        // the alert isn't the first thing the user sees on a cold launch; the
        // icon appears, then the modal.
        FirstRunDisclosure.presentIfNeeded()
    }

    /// Handler for `airassist://` URLs. Registered via `CFBundleURLTypes` in
    /// Info.plist; macOS calls this when the user opens such a URL from the
    /// browser, Shortcuts, Raycast, a shell (`open airassist://pause`), etc.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            URLSchemeHandler.handle(url, store: store)
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyService.shared.stop()
        store.stop()
        menuBarController?.teardown()
        menuBarController = nil
    }
}
