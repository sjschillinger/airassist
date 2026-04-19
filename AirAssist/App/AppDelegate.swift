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
        // After the risk disclosure is accepted (first launch only),
        // show the onboarding window so users get a productive default
        // instead of a blank menu-bar icon. Idempotent via its own key.
        OnboardingWindow.presentIfNeeded(store: store)
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

    /// Confirm quit while rules are live (#47) — prevents the "why did
    /// Chrome suddenly get faster / hotter" surprise after an accidental
    /// ⌘Q. Suppressed if the user is holding ⌥ (opt-quit convention for
    /// "I know what I'm doing, just do it").
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        let rulesLive = store.throttleRules.enabled && !store.liveThrottledPIDs.isEmpty
        guard rulesLive else { return .terminateNow }
        if NSEvent.modifierFlags.contains(.option) { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Air Assist?"
        alert.informativeText = """
        Air Assist is currently throttling \(store.liveThrottledPIDs.count) \
        process(es). Quitting will release them — they'll run at full speed \
        again until you relaunch the app.
        """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyService.shared.stop()
        store.stop()
        menuBarController?.teardown()
        menuBarController = nil
    }
}
