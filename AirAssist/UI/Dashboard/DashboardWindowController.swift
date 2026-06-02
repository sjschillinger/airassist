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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppStrings.Dashboard.title
        // Match DashboardView's content min so the window can't be forced
        // wider/taller than the user's saved frame on open (the old 520×380
        // window min vs 760-wide content mismatch made it open oversized).
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("AirAssist.Dashboard")
        let hostingController = NSHostingController(rootView: DashboardContainerView(store: store))
        // #14: Apple's accessibility audit flags the root NSHostingView
        // group as "Element has no description" unless we set one on the
        // AppKit side. SwiftUI's `.accessibilityLabel` on the root view
        // doesn't propagate here because the hosting group is upstream
        // of the SwiftUI view tree.
        hostingController.view.setAccessibilityLabel(AppStrings.Dashboard.title)
        window.contentViewController = hostingController
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // Only center on the very first appearance. After that, the
        // autosaved frame (keyed by `AirAssist.Dashboard`) restores
        // the user's last size and position.
        if window?.isVisible == false,
           UserDefaults.standard.string(forKey: "NSWindow Frame AirAssist.Dashboard") == nil {
            window?.center()
        }
        // Activate BEFORE showing — see PreferencesWindowController.show()
        // for rationale.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}
