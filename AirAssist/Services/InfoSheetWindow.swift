import AppKit

/// Lightweight non-modal floating window used by `FirstRunDisclosure` and
/// `WhatsNewSheet`. Replaces `NSAlert.runModal()` for those two flows
/// because `runModal` runs the runloop in `.modalPanel` mode, which
/// excludes the default-mode events that `application(_:open:)` is
/// dispatched on — meaning a Shortcut or `open airassist://...` invocation
/// that *triggers* a cold launch sees its URL queued behind the modal and
/// not handled until the user dismisses the sheet.
///
/// The replacement is a regular `NSWindow` shown via `NSWindowController`,
/// so the runloop keeps spinning in default mode while the user reads.
/// Same two-button affordance as the original alert; the window dismisses
/// itself after either button.
@MainActor
enum InfoSheetWindow {

    /// Single retained controller — keeps the window alive through the
    /// async lifecycle and prevents two stacked sheets if a caller fires
    /// twice. Cleared in the dismiss callback.
    private static var current: NSWindowController?

    /// Present a non-modal info sheet.
    /// - Parameters:
    ///   - title: window title (becomes the window-bar title and the bold heading).
    ///   - body: informative text. Newlines preserved.
    ///   - primaryButton: label for the dismissal button. Required.
    ///   - secondaryButton: optional label for a secondary action (e.g. "View License").
    ///   - secondaryAction: invoked if the user clicks the secondary button. Window
    ///     closes either way.
    ///   - onClose: invoked once the window is closed (for either button). Use this
    ///     to flip the "seen" UserDefaults marker so it isn't re-shown on next
    ///     launch.
    static func present(title: String,
                        body: String,
                        primaryButton: String,
                        secondaryButton: String? = nil,
                        secondaryAction: (() -> Void)? = nil,
                        onClose: @escaping () -> Void) {
        // If one is already up, just bring it forward — don't stack.
        if let existing = current, let w = existing.window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.autoresizingMask = [.width, .height]

        // Heading
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 14)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        // Body (selectable so users can copy lines if they want)
        let bodyField = NSTextField(wrappingLabelWithString: body)
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.isSelectable = true
        bodyField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bodyField)

        // Buttons
        let primary = NSButton(title: primaryButton, target: nil, action: nil)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"   // default button — Return triggers it
        primary.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(primary)

        var secondary: NSButton?
        if let secondaryTitle = secondaryButton {
            let b = NSButton(title: secondaryTitle, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(b)
            secondary = b
        }

        // Pending secondary action: if the user clicked Secondary, this gets
        // run *before* `onClose` in `windowWillClose`. Buttons just call
        // `window.close()` — the close observer is the single source of
        // truth for "fire onClose exactly once."
        var pendingSecondary: (() -> Void)?

        let primaryHolder = ActionHolder(action: { window.close() })
        primary.target = primaryHolder
        primary.action = #selector(ActionHolder.fire)
        objc_setAssociatedObject(primary, &Self.holderKey, primaryHolder, .OBJC_ASSOCIATION_RETAIN)

        if let secondary {
            let secondaryHolder = ActionHolder(action: {
                pendingSecondary = secondaryAction
                window.close()
            })
            secondary.target = secondaryHolder
            secondary.action = #selector(ActionHolder.fire)
            objc_setAssociatedObject(secondary, &Self.holderKey, secondaryHolder, .OBJC_ASSOCIATION_RETAIN)
        }

        // Layout
        let m: CGFloat = 18
        var constraints: [NSLayoutConstraint] = [
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            bodyField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            bodyField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            bodyField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            primary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            primary.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
            primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ]
        if let secondary {
            constraints += [
                secondary.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -10),
                secondary.bottomAnchor.constraint(equalTo: primary.bottomAnchor),
                secondary.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
                bodyField.bottomAnchor.constraint(lessThanOrEqualTo: secondary.topAnchor, constant: -m),
            ]
        } else {
            constraints += [
                bodyField.bottomAnchor.constraint(lessThanOrEqualTo: primary.topAnchor, constant: -m),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        window.contentView = content

        // Window-close (red traffic light, primary button, or secondary
        // button) all funnel here. Secondary button stashes its action in
        // `pendingSecondary`; we run it before `onClose` so the marker
        // flip and the side effect happen in a sensible order.
        let delegate = WindowCloseObserver(onClose: {
            pendingSecondary?()
            current = nil
            onClose()
        })
        window.delegate = delegate
        objc_setAssociatedObject(window, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        let wc = NSWindowController(window: window)
        current = wc

        // LSUIElement apps don't get focus by default — activate so the
        // window comes to the front instead of hiding behind whatever's
        // already focused.
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
    }

    private static var holderKey: UInt8 = 0
    private static var delegateKey: UInt8 = 0
}

/// Trampoline so we can hand a Swift closure to `NSButton.action` without
/// inheriting from NSObject in the caller. Retained via objc associated
/// objects on the button.
private final class ActionHolder: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Observes the window's close event so the "seen" marker is set even if
/// the user clicks the red traffic light instead of the primary button.
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    private var fired = false
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        // Buttons call onClose themselves; guard against double-fire by
        // checking before invoking.
        guard !fired else { return }
        fired = true
        onClose()
    }
}
