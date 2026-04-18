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

        // One-time legal/safety disclosure. Runs after the menu bar is up so
        // the alert isn't the first thing the user sees on a cold launch; the
        // icon appears, then the modal.
        FirstRunDisclosure.presentIfNeeded()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        menuBarController?.teardown()
        menuBarController = nil
    }
}
