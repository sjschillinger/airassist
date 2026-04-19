import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {
    private static var instance: PreferencesWindowController?

    static func shared(store: ThermalStore) -> PreferencesWindowController {
        if let existing = instance { return existing }
        let controller = PreferencesWindowController(store: store)
        instance = controller
        return controller
    }

    private init(store: ThermalStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 520, height: 460)
        window.title = AppStrings.Preferences.title
        window.setFrameAutosaveName("AirAssist.Preferences")
        window.contentViewController = NSHostingController(
            rootView: PreferencesView(store: store)
        )
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // Only center on the very first appearance. After that, the
        // autosaved frame (keyed by `AirAssist.Preferences`) restores
        // the user's last size and position.
        if window?.isVisible == false,
           UserDefaults.standard.string(forKey: "NSWindow Frame AirAssist.Preferences") == nil {
            window?.center()
        }
        // Activate BEFORE showing — for LSUIElement apps, doing this
        // in the other order can leave the window behind whatever app
        // currently holds focus. Not a bug we've hit in the wild, but
        // the skill reference flags it as a known pattern and costs
        // nothing to get right.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}
