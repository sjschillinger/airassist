import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController {
    private static var instance: DashboardWindowController?

    static func shared(store: ThermalStore) -> DashboardWindowController {
        if let existing = instance { return existing }
        let controller = DashboardWindowController(store: store)
        instance = controller
        return controller
    }

    private init(store: ThermalStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppStrings.Dashboard.title
        window.minSize = NSSize(width: 520, height: 380)
        window.setFrameAutosaveName("AirAssist.Dashboard")
        window.contentViewController = NSHostingController(rootView: DashboardContainerView(store: store))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
