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
        store = ThermalStore()
        store.start()
        menuBarController = MenuBarController(store: store)
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        menuBarController?.teardown()
        menuBarController = nil
    }
}
