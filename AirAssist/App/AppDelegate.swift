import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    // nonisolated(unsafe) lets the synchronous entry point assign these before
    // the main actor is running; all actual use happens from @MainActor methods.
    nonisolated(unsafe) private var store: ThermalStore!
    nonisolated(unsafe) private var menuBarController: MenuBarController?
    nonisolated(unsafe) private var memoryWatchdog: MemoryWatchdog?

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

        // Minimal main menu (#41 keyboard-nav) — gives ⌘W / ⌘Q / ⌘,
        // and the standard Edit shortcuts on any key window.
        AppMainMenu.install()

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

        // RSS tripwire (#49 follow-up). Cheap 5-min os_log breadcrumb if
        // the process ever balloons past 500 MB — catches amplified
        // NSHostingView regressions or new AirAssist leaks we haven't seen.
        let watchdog = MemoryWatchdog()
        watchdog.start()
        memoryWatchdog = watchdog

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
        let cancelButton = alert.addButton(withTitle: "Cancel")
        // ESC cancels — standard macOS convention. Without this the only way
        // out of the confirm is clicking Cancel, which breaks keyboard users
        // (and the tired muscle memory of everyone else).
        cancelButton.keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Action target for the "Preferences…" item in the main menu
    /// (installed by `AppMainMenu.install`). Dispatches up the responder
    /// chain because the menu item has no explicit target.
    @MainActor
    @objc func openPreferencesFromMenu(_ sender: Any?) {
        guard store != nil else { return }
        PreferencesWindowController.shared(store: store).show()
    }

    /// Action target for "Help → Show Welcome…". Reopens the onboarding
    /// sheet without clearing the seen-version flag, so it behaves like a
    /// revisit rather than re-running the first-launch ceremony.
    @MainActor
    @objc func showWelcomeFromMenu(_ sender: Any?) {
        guard store != nil else { return }
        OnboardingWindow.present(store: store, markSeen: false)
    }

    /// Action target for "Help → Export Diagnostics…". Same entry point as
    /// the button in General prefs; duplicated here so users can escape to
    /// a diagnostic bundle even when the prefs window is broken or they
    /// haven't learned where the button lives.
    @MainActor
    @objc func exportDiagnosticsFromMenu(_ sender: Any?) {
        guard store != nil else { return }
        DiagnosticBundle.exportInteractively(store: store)
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyService.shared.stop()
        memoryWatchdog?.stop()
        memoryWatchdog = nil
        store.stop()
        menuBarController?.teardown()
        menuBarController = nil
    }
}
