import AppKit

/// Minimal NSMainMenu for the LSUIElement app (#41 keyboard-nav).
///
/// Why we bother: without a main menu, ⌘W and ⌘Q key equivalents don't
/// dispatch through the normal responder chain — they're resolved by
/// NSApp walking `mainMenu` for a matching key equivalent. The status-item
/// menu has ⌘Q and ⌘D/⌘, but only while that menu is actually being
/// displayed; it does nothing when the Preferences or Dashboard window
/// has key focus.
///
/// Installing a tiny main menu (App + File) gives us standard, discoverable
/// ⌘W / ⌘Q behaviour everywhere, without turning the app into a regular
/// dock-present app. When LSUIElement=true and we activate via
/// `NSApp.activate(ignoringOtherApps:)`, this menu appears at the top of
/// the screen for as long as one of our windows is key — which is exactly
/// what the user expects.
///
/// We intentionally keep this tiny. No Edit/View/Window/Help submenus:
/// the popover, menu-bar quick menu, and Preferences/Dashboard windows
/// have their own affordances, and any more here would imply features the
/// app doesn't have.
@MainActor
enum AppMainMenu {
    static func install() {
        let mainMenu = NSMenu()

        // --- App menu (first menu; its title is ignored by AppKit,
        //     which always displays the bundle display name) ---
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let appName = ProcessInfo.processInfo.processName

        appMenu.addItem(NSMenuItem(
            title: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        // Routed through AppDelegate (which owns the shared store).
        // Action has no explicit target so it dispatches up the responder
        // chain and reaches NSApp.delegate.
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(AppDelegate.openPreferencesFromMenu(_:)),
            keyEquivalent: ","
        )
        prefsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        // NOTE: uses `terminate:` so `applicationShouldTerminate` still
        // runs — that's what powers the "rules are live, are you sure?"
        // confirmation (#47).
        appMenu.addItem(NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // --- File menu: just Close Window (⌘W) ---
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))

        // --- Edit menu: standard text-editing shortcuts for the
        //     TextFields in Preferences/Onboarding. Without this,
        //     ⌘A/⌘C/⌘V/⌘X/⌘Z don't work in focused text fields
        //     because nothing on the responder chain has bound them. ---
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redo = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        ))

        // --- Help menu: Show Welcome… lets users re-open the onboarding
        //     sheet after first run. `OnboardingWindow.present(…,
        //     markSeen: false)` was designed exactly for this but had no
        //     visible entry point before. Dispatches up the responder
        //     chain to AppDelegate, which owns the store. ---
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(NSMenuItem(
            title: "Show Welcome…",
            action: #selector(AppDelegate.showWelcomeFromMenu(_:)),
            keyEquivalent: ""
        ))
        helpMenu.addItem(.separator())
        helpMenu.addItem(NSMenuItem(
            title: "Export Diagnostics…",
            action: #selector(AppDelegate.exportDiagnosticsFromMenu(_:)),
            keyEquivalent: ""
        ))

        NSApp.mainMenu = mainMenu
    }
}

