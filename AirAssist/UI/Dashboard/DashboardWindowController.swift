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
        if window?.isVisible == false { recenterIfFramePoor() }
        // Activate BEFORE showing — see PreferencesWindowController.show()
        // for rationale.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}

extension NSWindowController {
    /// Place a soon-to-be-shown window at a sensible on-screen position.
    ///
    /// We keep `setFrameAutosaveName` so a window remembers a size/position
    /// the user actually chose — but a plain `window.center()` only ran when
    /// *no* frame was saved, so a stale autosaved frame (or one written
    /// before the window had a screen) could pin every window to the left
    /// edge at x≈0 and never self-correct. This recenters explicitly when
    /// the current frame is off-screen or jammed against the left edge,
    /// and leaves genuine user positions untouched.
    func recenterIfFramePoor() {
        guard let window,
              let vis = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let f = window.frame
        let overlap = vis.intersection(f)
        let mostlyVisible = overlap.width >= f.width * 0.6
            && overlap.height >= f.height * 0.6
        let pinnedLeft = f.minX <= vis.minX + 2
        guard !mostlyVisible || pinnedLeft else { return }
        let origin = NSPoint(
            x: vis.minX + (vis.width  - f.width)  / 2,
            y: vis.minY + (vis.height - f.height) / 2
        )
        window.setFrameOrigin(origin)
    }
}
