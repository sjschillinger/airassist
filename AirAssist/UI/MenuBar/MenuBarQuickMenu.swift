import AppKit

/// Right-click / control-click menu on the status item. Mirrors the core
/// popover actions so power users can pause for an hour or open the
/// dashboard without going through the full popover.
///
/// Extracted from `MenuBarController` to isolate all the `@objc` target
/// plumbing in one place. The controller owns an instance and forwards
/// the button's click event here when the modifier/right-click condition
/// is met.
@MainActor
final class MenuBarQuickMenu: NSObject {
    private weak var store: ThermalStore?
    private let openDashboard: () -> Void
    private let openPreferences: () -> Void

    init(store: ThermalStore,
         openDashboard: @escaping () -> Void,
         openPreferences: @escaping () -> Void) {
        self.store = store
        self.openDashboard = openDashboard
        self.openPreferences = openPreferences
        super.init()
    }

    /// Present the quick menu attached to `statusItem`. Caller must close
    /// any popover first so the menu doesn't fight for keyboard focus.
    func present(on statusItem: NSStatusItem) {
        guard let button = statusItem.button, let store else { return }

        let menu = NSMenu()

        let dashItem = NSMenuItem(title: "Open Dashboard",
                                  action: #selector(qmDashboard),
                                  keyEquivalent: "d")
        dashItem.target = self
        dashItem.keyEquivalentModifierMask = [.command]
        menu.addItem(dashItem)

        let prefItem = NSMenuItem(title: "Preferences…",
                                  action: #selector(qmPreferences),
                                  keyEquivalent: ",")
        prefItem.target = self
        prefItem.keyEquivalentModifierMask = [.command]
        menu.addItem(prefItem)

        menu.addItem(.separator())

        if store.isPauseActive {
            let resume = NSMenuItem(title: "Resume throttling",
                                    action: #selector(qmResume),
                                    keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        } else {
            let pauseParent = NSMenuItem(title: "Pause throttling",
                                         action: nil, keyEquivalent: "")
            let pauseSub = NSMenu()
            pauseSub.addItem(makePauseItem("15 minutes",   seconds: 15 * 60))
            pauseSub.addItem(makePauseItem("1 hour",       seconds: 60 * 60))
            pauseSub.addItem(makePauseItem("4 hours",      seconds: 4 * 60 * 60))
            pauseSub.addItem(makePauseItem("Until quit",   seconds: nil))
            pauseParent.submenu = pauseSub
            menu.addItem(pauseParent)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Air Assist",
                              action: #selector(qmQuit),
                              keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        // Detach the menu after it closes so right-click stays available.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func makePauseItem(_ title: String, seconds: TimeInterval?) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(qmPause(_:)),
                              keyEquivalent: "")
        item.target = self
        item.tag = seconds.map { Int($0) } ?? -1
        return item
    }

    @objc private func qmDashboard()    { openDashboard() }
    @objc private func qmPreferences()  { openPreferences() }
    @objc private func qmResume()       { store?.resumeThrottling() }
    @objc private func qmQuit()         { NSApp.terminate(nil) }
    @objc private func qmPause(_ sender: NSMenuItem) {
        let duration: TimeInterval? = sender.tag == -1 ? nil : TimeInterval(sender.tag)
        store?.pauseThrottling(for: duration)
    }
}
