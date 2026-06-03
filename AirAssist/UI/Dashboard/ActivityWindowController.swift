import AppKit
import SwiftUI

/// Standalone window for the Activity process monitor — the app's
/// equivalent of macOS Activity Monitor. Kept out of the Dashboard
/// (which is glanceable monitoring) and out of Preferences (which is
/// configuration): the live process list with inline limit controls is
/// its own tool, opened on demand from the menu bar, a Preferences
/// button, or the `airassist://open-activity` URL.
@MainActor
final class ActivityWindowController: NSWindowController {
    private static var instance: ActivityWindowController?

    static func shared(store: ThermalStore) -> ActivityWindowController {
        if let existing = instance { return existing }
        let controller = ActivityWindowController(store: store)
        instance = controller
        return controller
    }

    private init(store: ThermalStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Activity"
        window.minSize = NSSize(width: 560, height: 400)
        window.setFrameAutosaveName("AirAssist.Activity")
        let hosting = NSHostingController(rootView: ActivityMonitorView(store: store))
        hosting.view.setAccessibilityLabel("Activity")
        window.contentViewController = hosting
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        if window?.isVisible == false { recenterIfFramePoor() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}
