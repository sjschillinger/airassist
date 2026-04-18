import AppKit
import SwiftUI


@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store: ThermalStore
    private var keyMonitor: Any?
    private var appearanceObserver: NSKeyValueObservation?

    init(store: ThermalStore) {
        self.store = store
        setupStatusItem()
        setupPopover()
        // Cmd+, fires only when our app is key (i.e. popover is open)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self?.openPreferences()
                return nil
            }
            return event
        }
        // Re-render immediately when the user toggles Appearance / Increase Contrast
        // so tinted (red/orange) states update right away instead of waiting for
        // the next 2s poll. (Template images auto-adapt — this is for the baked-
        // in-color path only, but it's cheap to just re-run syncButton either way.)
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncButton() }
        }
        // Defer observation to next run loop so status item finishes its own layout first
        DispatchQueue.main.async { [weak self] in self?.observeStore() }
    }

    func teardown() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if popover.isShown { popover.performClose(nil) }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Status item (pure AppKit — no NSHostingView to avoid layout recursion on macOS 26)

    // Base widths & font sizes, calibrated for the standard 22pt menu bar.
    // On displays with a taller bar (macOS HiDPI scaling / larger menu bar
    // accessibility), both the slot width and font size scale proportionally
    // so content fills the bar at the same visual density. NEVER use
    // NSStatusItem.variableLength — status items are hosted in ControlCenter's
    // process via scene hosting on macOS 15+/26, and every content change
    // triggers a cross-process _viewSizeDidChange → [NSStatusItem setLength:]
    // call; any invalid transient size throws an uncaught NSException inside
    // ControlCenter and crashes the menu bar agent. Fixed widths skip that.
    private enum BaseSize {
        static let referenceBarHeight: CGFloat = 22
        // Slot widths at reference bar height
        static let singleWidth: CGFloat     = 56
        static let sideBySideWidth: CGFloat = 86
        static let stackedWidth: CGFloat    = 44
        // Font sizes at reference bar height
        static let singleFontPt: CGFloat    = 12
        static let stackedFontPt: CGFloat   = 10
        static let iconPt: CGFloat          = 13
    }

    /// Scale factor derived from the *current* menu bar thickness vs. the
    /// 22pt reference. On a standard bar this is 1.0; on a scaled-up bar it
    /// grows proportionally (e.g. 1.45 if the bar is 32pt).
    private static var barScale: CGFloat {
        max(1.0, NSStatusBar.system.thickness / BaseSize.referenceBarHeight)
    }
    private static var widthSingle: CGFloat     { BaseSize.singleWidth * barScale }
    private static var widthSideBySide: CGFloat { BaseSize.sideBySideWidth * barScale }
    private static var widthStacked: CGFloat    { BaseSize.stackedWidth * barScale }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: Self.widthSingle)
        guard let button = statusItem?.button else { return }
        // NEVER replace button.cell — NSStatusBarButton's cell has transparent/menu-bar
        // styling configured invisibly by the system; replacing it breaks appearance.
        button.image = NSImage(systemSymbolName: "thermometer.medium",
                               accessibilityDescription: AppStrings.appName)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeft
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func syncButton() {
        guard let item = statusItem, let button = item.button else { return }
        let defaults = UserDefaults.standard

        let unit     = TempUnit(rawValue: defaults.integer(forKey: "tempUnit")) ?? .celsius
        let slot1Cat = defaults.string(forKey: "menuBarSlot1Category") ?? SlotCategory.highest.rawValue
        let slot1Val = defaults.string(forKey: "menuBarSlot1Value")    ?? SensorCategory.cpu.rawValue
        let slot2Cat = defaults.string(forKey: "menuBarSlot2Category") ?? SlotCategory.none.rawValue
        let slot2Val = defaults.string(forKey: "menuBarSlot2Value")    ?? ""
        let layout   = MenuBarLayout(rawValue: defaults.string(forKey: "menuBarLayout") ?? "") ?? .single

        let state = store.hottestSensor?.thresholdState(using: store.thresholds) ?? .unknown
        let iconName: String
        switch state {
        case .hot:            iconName = "thermometer.high"
        case .warm:           iconName = "thermometer.medium"
        case .cool, .unknown: iconName = "thermometer.medium"
        }
        let tint: NSColor?
        switch state {
        case .hot:            tint = .systemRed
        case .warm:           tint = .systemOrange
        case .cool, .unknown: tint = nil
        }

        let v1 = store.temperature(category: slot1Cat, value: slot1Val)
        let v2 = layout == .single ? nil : store.temperature(category: slot2Cat, value: slot2Val)

        let targetLength: CGFloat
        switch layout {
        case .single:     targetLength = Self.widthSingle
        case .sideBySide: targetLength = Self.widthSideBySide
        case .stacked:    targetLength = Self.widthStacked
        }

        // Render the entire content (icon + text, or two-line text) into a
        // single NSImage sized exactly to the status item. NSButtonCell
        // vertically centers images by default, so this gives pixel-accurate
        // centering across all three layouts — no paragraph-style hacks, no
        // attributedTitle top-alignment quirks. It also removes per-poll
        // mutation of imagePosition / attributedTitle, further reducing
        // cross-process size churn with ControlCenter.
        let rendered = Self.renderMenuBarImage(
            layout: layout,
            v1: v1, v2: v2, unit: unit,
            iconName: iconName, tint: tint,
            width: targetLength
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if item.length != targetLength { item.length = targetLength }
            if button.imagePosition != .imageOnly { button.imagePosition = .imageOnly }
            if button.contentTintColor != nil { button.contentTintColor = nil } // we bake tint in
            if button.attributedTitle.length != 0 {
                button.attributedTitle = NSAttributedString(string: "")
            }
            button.image = rendered
        }
    }

    // MARK: - Off-screen rendering (keeps everything vertically centered)

    private static let barHeight: CGFloat = NSStatusBar.system.thickness  // 22 on modern macOS

    private static func renderMenuBarImage(
        layout: MenuBarLayout,
        v1: Double?, v2: Double?, unit: TempUnit,
        iconName: String, tint: NSColor?,
        width: CGFloat
    ) -> NSImage {
        let size = NSSize(width: width, height: barHeight)
        let img = NSImage(size: size, flipped: false) { _ in
            switch layout {
            case .single:
                drawIconPlusText(
                    text: v1.map(unit.format) ?? "",
                    iconName: iconName, tint: tint,
                    size: size
                )
            case .sideBySide:
                var parts: [String] = []
                if let v1 { parts.append(unit.format(v1)) }
                if let v2 { parts.append(unit.format(v2)) }
                drawIconPlusText(
                    text: parts.joined(separator: "  "),
                    iconName: iconName, tint: tint,
                    size: size
                )
            case .stacked:
                drawStackedText(
                    top:    v1.map(unit.format) ?? "–",
                    bottom: v2.map(unit.format) ?? "–",
                    size: size
                )
            }
            return true
        }
        // Only treat as template (auto-tinted by AppKit) when there's no explicit tint.
        img.isTemplate = (tint == nil)
        return img
    }

    private static func drawIconPlusText(
        text: String, iconName: String, tint: NSColor?,
        size: NSSize
    ) {
        let scale = barScale
        let iconConfig = NSImage.SymbolConfiguration(pointSize: BaseSize.iconPt * scale, weight: .regular)
        guard let baseIcon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(iconConfig) else { return }
        let iconSize = baseIcon.size
        let font: NSFont = .monospacedDigitSystemFont(ofSize: BaseSize.singleFontPt * scale, weight: .regular)
        let textColor: NSColor = tint ?? .labelColor
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: textAttrs)

        let gap: CGFloat = 3
        let totalWidth = iconSize.width + (text.isEmpty ? 0 : gap + textSize.width)
        let startX = (size.width - totalWidth) / 2

        // Icon
        let iconRect = NSRect(
            x: startX,
            y: (size.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        if let tint {
            tint.set()
            let tinted = baseIcon.copy() as! NSImage
            tinted.isTemplate = false
            tinted.lockFocus()
            tint.set()
            let r = NSRect(origin: .zero, size: iconSize)
            r.fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: iconRect)
        } else {
            // Template: AppKit will tint this image based on appearance when drawn in menu bar.
            baseIcon.draw(in: iconRect)
        }

        // Text
        if !text.isEmpty {
            let textRect = NSRect(
                x: startX + iconSize.width + gap,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: textAttrs)
        }
    }

    private static func drawStackedText(top: String, bottom: String, size: NSSize) {
        let font: NSFont = .monospacedDigitSystemFont(ofSize: BaseSize.stackedFontPt * barScale, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let topSize    = (top    as NSString).size(withAttributes: attrs)
        let bottomSize = (bottom as NSString).size(withAttributes: attrs)
        let lineHeight = max(topSize.height, bottomSize.height)
        let totalHeight = lineHeight * 2
        let blockY = (size.height - totalHeight) / 2

        let topRect = NSRect(
            x: (size.width - topSize.width) / 2,
            y: blockY + lineHeight,
            width: topSize.width,
            height: lineHeight
        )
        let bottomRect = NSRect(
            x: (size.width - bottomSize.width) / 2,
            y: blockY,
            width: bottomSize.width,
            height: lineHeight
        )
        (top    as NSString).draw(in: topRect,    withAttributes: attrs)
        (bottom as NSString).draw(in: bottomRect, withAttributes: attrs)
    }

    private func monoAttrs(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
    }

    // MARK: - Observation (re-registers itself on each change)

    private func observeStore() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            // Track both the sensor list and each individual currentValue so that
            // all slot modes (highest, average, individual) update on every poll
            _ = store.sensors.count
            store.enabledSensors.forEach { _ = $0.currentValue }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncButton()
                self?.observeStore()
            }
        }
    }

    // MARK: - Popover (content created lazily on first open to avoid startup layout recursion)

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
    }

    private func ensurePopoverContent() {
        guard popover.contentViewController == nil else { return }
        let vc = NSHostingController(rootView: MenuBarPopoverView(
            store: store,
            onDashboard:   { [weak self] in self?.openDashboard() },
            onPreferences: { [weak self] in self?.openPreferences() },
            onQuit:        { NSApp.terminate(nil) }
        ))
        vc.sizingOptions = []
        popover.contentSize = NSSize(width: 260, height: 460)
        popover.contentViewController = vc
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            ensurePopoverContent()
            popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openDashboard() {
        popover.performClose(nil)
        DashboardWindowController.shared(store: store).show()
    }

    func openPreferences() {
        popover.performClose(nil)
        PreferencesWindowController.shared(store: store).show()
    }
}
