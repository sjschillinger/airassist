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
    private let openActivity: () -> Void
    private let openPreferences: () -> Void

    init(store: ThermalStore,
         openDashboard: @escaping () -> Void,
         openActivity: @escaping () -> Void,
         openPreferences: @escaping () -> Void) {
        self.store = store
        self.openDashboard = openDashboard
        self.openActivity = openActivity
        self.openPreferences = openPreferences
        super.init()
    }

    /// Present the quick menu attached to `statusItem`. Caller must close
    /// any popover first so the menu doesn't fight for keyboard focus.
    func present(on statusItem: NSStatusItem) {
        guard let button = statusItem.button, let store else { return }

        let menu = NSMenu()

        // Update nudge — only rendered when the daily check (or the
        // user's last manual check) found a release newer than ours.
        // Clicking opens the release page in their browser; users on
        // Homebrew simply run `brew upgrade --cask airassist`.
        if let newer = UpdateCheckService.shared.latestVersion {
            let upd = NSMenuItem(title: String(localized: "↑ Version \(newer) available — Get it"),
                                 action: #selector(qmOpenReleasePage),
                                 keyEquivalent: "")
            upd.target = self
            menu.addItem(upd)
            menu.addItem(.separator())
        }

        let dashItem = NSMenuItem(title: String(localized: "Open Dashboard"),
                                  action: #selector(qmDashboard),
                                  keyEquivalent: "d")
        dashItem.target = self
        dashItem.keyEquivalentModifierMask = [.command]
        menu.addItem(dashItem)

        let activityItem = NSMenuItem(title: String(localized: "Open Activity"),
                                      action: #selector(qmActivity),
                                      keyEquivalent: "a")
        activityItem.target = self
        activityItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(activityItem)

        let prefItem = NSMenuItem(title: String(localized: "Preferences…"),
                                  action: #selector(qmPreferences),
                                  keyEquivalent: ",")
        prefItem.target = self
        prefItem.keyEquivalentModifierMask = [.command]
        menu.addItem(prefItem)

        // Escape hatch: throttle the app the user is currently interacting
        // with. Only offered when that app isn't us — we'd refuse our own
        // PID anyway, but the menu item would be misleading.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != getpid() {
            let appName = frontmost.localizedName ?? String(localized: "Frontmost")
            let title = String(localized: "Throttle \(appName) at 30%")
            let throttleItem = NSMenuItem(title: title,
                                          action: #selector(qmThrottleFrontmost),
                                          keyEquivalent: "")
            throttleItem.target = self
            menu.addItem(throttleItem)
        }

        menu.addItem(.separator())

        if store.isPauseActive {
            let resume = NSMenuItem(title: String(localized: "Resume throttling"),
                                    action: #selector(qmResume),
                                    keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        } else {
            let pauseParent = NSMenuItem(title: String(localized: "Pause throttling"),
                                         action: nil, keyEquivalent: "")
            let pauseSub = NSMenu()
            pauseSub.addItem(makePauseItem(String(localized: "15 minutes"), seconds: 15 * 60))
            pauseSub.addItem(makePauseItem(String(localized: "1 hour"),     seconds: 60 * 60))
            pauseSub.addItem(makePauseItem(String(localized: "4 hours"),    seconds: 4 * 60 * 60))
            pauseSub.addItem(makePauseItem(String(localized: "Until quit"), seconds: nil))
            pauseParent.submenu = pauseSub
            menu.addItem(pauseParent)
        }

        menu.addItem(.separator())

        // Stay Awake submenu — caffeinate-style controls. The current
        // mode gets a ✓, and the display-timeout variant picks its
        // minutes from the user's prefs default (falls back to 10).
        let stayAwakeParent = NSMenuItem(title: String(localized: "Stay Awake"),
                                         action: nil, keyEquivalent: "")
        stayAwakeParent.submenu = makeStayAwakeSubmenu(currentMode: store.stayAwake.currentMode)
        menu.addItem(stayAwakeParent)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Air Assist"),
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

    // MARK: - Stay Awake submenu

    /// Build the Stay Awake submenu. The current mode gets a checkmark.
    /// The display-timeout item uses the `stayAwake.displayTimeoutMinutes`
    /// preference (default 10 min) so the user can pre-configure once
    /// and then toggle from the menu without drilling into prefs.
    private func makeStayAwakeSubmenu(currentMode: StayAwakeService.Mode) -> NSMenu {
        let submenu = NSMenu()

        let timeoutMinutes: Int = {
            let m = UserDefaults.standard.integer(forKey: "stayAwake.displayTimeoutMinutes")
            return m > 0 ? m : 10
        }()

        let options: [(title: String, mode: StayAwakeService.Mode)] = [
            (String(localized: "Off"),                                .off),
            (String(localized: "Keep system awake (allow display sleep)"), .system),
            (String(localized: "Keep system & display awake"),        .display),
            (String(localized: "Display on \(timeoutMinutes) min, then system only"), .displayThenSystem(minutes: timeoutMinutes)),
        ]

        for (title, mode) in options {
            let item = NSMenuItem(title: title,
                                  action: #selector(qmStayAwake(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            if mode == currentMode { item.state = .on }
            submenu.addItem(item)
        }

        // Live countdown row when a display-timeout is counting down.
        if let remaining = store?.stayAwake.displayTimerRemaining, remaining > 0 {
            submenu.addItem(.separator())
            let mins = Int(remaining / 60)
            let secs = Int(remaining.truncatingRemainder(dividingBy: 60))
            let label = String(format: String(localized: "Display sleeps in %d:%02d"), mins, secs)
            let countdown = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            countdown.isEnabled = false
            submenu.addItem(countdown)
        }

        return submenu
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
    @objc private func qmActivity()     { openActivity() }
    @objc private func qmPreferences()  { openPreferences() }
    @objc private func qmResume()       { store?.resumeThrottling() }
    @objc private func qmQuit()         { NSApp.terminate(nil) }
    @objc private func qmPause(_ sender: NSMenuItem) {
        let duration: TimeInterval? = sender.tag == -1 ? nil : TimeInterval(sender.tag)
        store?.pauseThrottling(for: duration)
    }
    @objc private func qmStayAwake(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? StayAwakeService.Mode else { return }
        store?.setStayAwakeMode(mode)
    }

    @objc private func qmOpenReleasePage() {
        UpdateCheckService.shared.openReleasePage()
    }

    @objc private func qmThrottleFrontmost() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != getpid() else { return }
        store?.throttleFrontmost(
            pid: frontmost.processIdentifier,
            name: frontmost.localizedName ?? "Frontmost",
            duty: 0.30
        )
    }
}
