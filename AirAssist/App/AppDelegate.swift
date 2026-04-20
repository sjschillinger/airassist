import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    // nonisolated(unsafe) lets the synchronous entry point assign these before
    // the main actor is running; all actual use happens from @MainActor methods.
    nonisolated(unsafe) private var store: ThermalStore!
    nonisolated(unsafe) private var menuBarController: MenuBarController?
    nonisolated(unsafe) private var memoryWatchdog: MemoryWatchdog?

    nonisolated static func main() {
        // Single-instance guard. Two AirAssist instances racing on the same
        // PIDs is catastrophic — both would fight over the inflight file and
        // could SIGSTOP each other's targets with no coordination. If another
        // instance is already running, bring it forward and exit silently.
        //
        // Using bundle-ID lookup rather than a lockfile means this self-heals
        // across unclean terminations (no stale lock to clean up).
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sjschillinger.airassist"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            existing.activate(options: [])
            FileHandle.standardError.write(Data(
                "AirAssist is already running (pid=\(existing.processIdentifier)); exiting.\n".utf8
            ))
            exit(0)
        }

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

        // Tier 1: register the bundled rescue LaunchAgent so
        // `airassist-rescue` runs once per login even if the app itself is
        // never re-opened. Defense in depth against crashes that leave
        // pids frozen. Idempotent across relaunches; failure is non-fatal.
        RescueAgentRegistrar.registerIfNeeded()

        // Tier 2: subscribe to MetricKit BEFORE any heavy work starts, so
        // the subscriber is installed by the time macOS delivers the
        // previous launch's diagnostic payload (delivery happens early in
        // app lifecycle — miss it here and the payload is lost for good).
        MetricKitReporter.shared.start()

        // Tier 4: daily GitHub-Releases-API check. No-op if the user has
        // turned off automaticChecksEnabled in Preferences. Manual
        // "Check for Updates…" still works either way.
        UpdateCheckService.shared.start()

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
        // `application(_:open:)` can fire before `applicationDidFinishLaunching`
        // on a cold launch triggered by `open airassist://...`. `store` is an
        // IUO that crashes on unwrap if not yet assigned. Drop URLs that arrive
        // early; the user can re-trigger them once the app is up.
        guard store != nil else { return }
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
    /// Action target for the app-menu "Check for Updates…" item. Forces
    /// an immediate check; on completion, shows either the release page
    /// (if newer) or an "up to date" alert so the user gets explicit
    /// feedback from the click.
    @MainActor
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        Task { @MainActor in
            await UpdateCheckService.shared.checkNow()
            if let newer = UpdateCheckService.shared.latestVersion {
                // A newer release exists — hand the user the release page
                // rather than trying to install over a running ad-hoc app.
                let alert = NSAlert()
                alert.messageText = "Air Assist \(newer) is available"
                alert.informativeText = """
                You're running \(UpdateCheckService.currentVersion). \
                Open the release page to download and install.

                Homebrew users can instead run:
                    brew upgrade --cask airassist
                """
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    UpdateCheckService.shared.openReleasePage()
                }
            } else {
                let alert = NSAlert()
                alert.messageText = "Air Assist is up to date"
                alert.informativeText = "You're running \(UpdateCheckService.currentVersion), the latest release."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

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
        MetricKitReporter.shared.stop()
        store.stop()
        menuBarController?.teardown()
        menuBarController = nil
    }
}
