import AppKit
import SwiftUI

/// Coordinator for the menu bar: owns the NSStatusItem, routes clicks to
/// popover or quick-menu, and keeps the button image synchronised with
/// `ThermalStore` state.
///
/// Rendering lives in `MenuBarIconRenderer`; the right-click action sheet
/// lives in `MenuBarQuickMenu`. This file deliberately stays small — any
/// logic that isn't "own the NSStatusItem, observe the store, open
/// popover/menu/preferences" belongs in one of those two collaborators.
///
/// IMPORTANT: never use `NSStatusItem.variableLength`. Status items are
/// hosted in ControlCenter's process via scene hosting on macOS 15+/26,
/// and every content change triggers a cross-process `_viewSizeDidChange`
/// → `[NSStatusItem setLength:]` call; any invalid transient size throws
/// an uncaught NSException inside ControlCenter and crashes the menu bar
/// agent. Fixed widths sidestep that.
///
/// Likewise, never replace `NSStatusBarButton.cell` — the menu bar uses
/// transparent styling configured invisibly by the system on that cell.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store: ThermalStore
    private var quickMenu: MenuBarQuickMenu!
    private var keyMonitor: Any?
    private var appearanceObserver: NSKeyValueObservation?

    // Heartbeat pulse: a timer re-renders the button at ~8 Hz while the
    // throttle dot is visible so it slowly fades in and out. Timer is
    // started/stopped on demand from syncButton() to avoid wasting CPU
    // when nothing is being throttled.
    private var pulseTimer: Timer?
    private var pulseStart: Date?
    private var defaultsObserver: NSObjectProtocol?
    /// Seconds for one full fade-in/out cycle. 1.6s ≈ resting human pulse,
    /// slow enough to read as deliberate rather than nervous.
    private static let pulsePeriod: TimeInterval = 1.6

    init(store: ThermalStore) {
        self.store = store
        self.quickMenu = MenuBarQuickMenu(
            store: store,
            openDashboard:   { [weak self] in self?.openDashboard() },
            openPreferences: { [weak self] in self?.openPreferences() }
        )
        setupStatusItem()
        setupPopover()
        // Cmd+, and Cmd+D fire only when our app is key (e.g. popover open).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case ",":
                self?.openPreferences()
                return nil
            case "d", "D":
                self?.openDashboard()
                return nil
            default:
                return event
            }
        }
        // Re-render immediately when the user toggles Appearance / Increase
        // Contrast so tinted (red/orange) states update right away instead of
        // waiting for the next 2s poll.
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncButton() }
        }
        // UserDefaults.didChangeNotification fires on every @AppStorage write,
        // so toggling "Show icon" (or any other menu-bar pref) re-renders the
        // status item immediately. Cheap: syncButton() bails on unchanged state.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncButton() }
        }
        // Defer observation to next run loop so status item finishes its own
        // layout first.
        DispatchQueue.main.async { [weak self] in self?.observeStore() }
    }

    func teardown() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        if let o = defaultsObserver {
            NotificationCenter.default.removeObserver(o)
            defaultsObserver = nil
        }
        stopPulse()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if popover.isShown { popover.performClose(nil) }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Pulse driver

    private func startPulseIfNeeded() {
        guard pulseTimer == nil else { return }
        pulseStart = Date()
        // 8 Hz is smooth enough to read as a fade without thrashing the
        // cross-process ControlCenter notification chain.
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.renderWithPulse() }
        }
        if let t = pulseTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseStart = nil
    }

    /// Compute current pulsePhase (0…1) and redraw. Separate from syncButton()
    /// to avoid re-reading every store value 8×/s — we just re-render with the
    /// existing state and a new phase.
    private func renderWithPulse() {
        guard pulseTimer != nil else { return }
        syncButton()
    }

    private func currentPulsePhase() -> CGFloat {
        guard let start = pulseStart else { return 1.0 }
        let t = Date().timeIntervalSince(start)
        // Raised sine: 0.5 + 0.5·sin(…) sweeps 0 → 1 → 0 smoothly.
        let twoPi = 2 * Double.pi
        let phase = 0.5 + 0.5 * sin(twoPi * t / Self.pulsePeriod - .pi / 2)
        return CGFloat(phase)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarIconRenderer.widthSingle)
        guard let button = statusItem?.button else { return }
        // Use our brand glyph as the placeholder pre-first-sync; falls back to
        // the SF Symbol if the asset ever goes missing. isTemplate is already
        // set by the imageset's template-rendering intent, but belt-and-braces.
        let initialImage = NSImage(named: "MenuBarGlyph")
            ?? NSImage(systemSymbolName: "thermometer.medium",
                       accessibilityDescription: AppStrings.appName)
        initialImage?.isTemplate = true
        initialImage?.accessibilityDescription = AppStrings.appName
        button.image = initialImage
        button.imagePosition = .imageLeft
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        // Default when the key has never been written is `true`, matching the
        // @AppStorage default in MenuBarPrefsView. object(forKey:) lets us
        // distinguish "never set" from "explicitly false".
        let showIcon = (defaults.object(forKey: "showMenuBarIcon") as? Bool) ?? true

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
        case .single:
            targetLength = showIcon ? MenuBarIconRenderer.widthSingle
                                    : MenuBarIconRenderer.widthSingleNoIcon
        case .sideBySide:
            targetLength = showIcon ? MenuBarIconRenderer.widthSideBySide
                                    : MenuBarIconRenderer.widthSideBySideNoIcon
        case .stacked:
            // Stacked layout is text-only by design — showIcon doesn't apply.
            targetLength = MenuBarIconRenderer.widthStacked
        }

        // Throttle indicator dot: red if cap is breached, orange if only rules.
        let throttleDot: NSColor? = {
            if store.isPauseActive { return nil }
            if store.governor.isTempThrottling { return .systemRed }
            if store.governor.isCPUThrottling  { return .systemOrange }
            if !store.liveThrottledPIDs.isEmpty { return .systemOrange }
            return nil
        }()

        // Start or stop the pulse depending on whether a throttle dot is
        // being drawn this frame. pulsePhase is sampled from the pulse's
        // start time so the fade is monotonic and frame-rate independent.
        if throttleDot != nil {
            startPulseIfNeeded()
        } else {
            stopPulse()
        }
        let phase = currentPulsePhase()

        let rendered = MenuBarIconRenderer.render(
            layout: layout,
            v1: v1, v2: v2, unit: unit,
            iconName: iconName, tint: tint,
            showIcon: showIcon,
            throttleDot: throttleDot,
            pulsePhase: phase,
            width: targetLength
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if item.length != targetLength { item.length = targetLength }
            if button.imagePosition != .imageOnly { button.imagePosition = .imageOnly }
            if button.contentTintColor != nil { button.contentTintColor = nil }
            if button.attributedTitle.length != 0 {
                button.attributedTitle = NSAttributedString(string: "")
            }
            button.image = rendered
        }

        // VoiceOver: without this, the rendered composite image is read as
        // raw digits ("84 degrees") with no app context. Set it on both the
        // image (for direct inspection) and the button (for AX traversal).
        let a11y = accessibilityDescription(
            v1: v1, v2: v2, unit: unit, state: state,
            isPaused: store.isPauseActive,
            throttleDotRed: throttleDot == .systemRed
        )
        rendered.accessibilityDescription = a11y
        button.setAccessibilityLabel(a11y)
        button.setAccessibilityTitle(a11y)
    }

    /// Build a VoiceOver-friendly sentence summarising the menu bar state.
    /// Example outputs:
    ///   - "Air Assist. CPU 84 degrees Celsius. Hot. Throttling active."
    ///   - "Air Assist. CPU 67, GPU 61 degrees. Paused."
    ///   - "Air Assist. Sensors unavailable."
    private func accessibilityDescription(
        v1: Double?, v2: Double?,
        unit: TempUnit,
        state: ThresholdState,
        isPaused: Bool,
        throttleDotRed: Bool
    ) -> String {
        var parts: [String] = [AppStrings.appName]
        if let v1 {
            let v1Str = unit.format(v1)
            if let v2 {
                parts.append("\(v1Str), \(unit.format(v2))")
            } else {
                parts.append(v1Str)
            }
        } else {
            parts.append("sensors unavailable")
        }
        switch state {
        case .hot:  parts.append("hot")
        case .warm: parts.append("warm")
        case .cool: parts.append("cool")
        case .unknown: break
        }
        if isPaused {
            parts.append("paused")
        } else if throttleDotRed {
            parts.append("throttling active")
        } else if !store.liveThrottledPIDs.isEmpty {
            parts.append("rules active")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Observation

    private func observeStore() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = store.sensors.count
            store.enabledSensors.forEach { _ = $0.currentValue }
            _ = store.governor.isTempThrottling
            _ = store.governor.isCPUThrottling
            _ = store.liveThrottledPIDs.count
            _ = store.isPauseActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncButton()
                self?.observeStore()
            }
        }
    }

    // MARK: - Popover

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
        // Let SwiftUI drive the popover height from the hosted view's
        // intrinsic size, so Summary mode (shorter) doesn't leave a gap
        // above the header and Detailed mode can grow within its
        // maxHeight(260) cap without clipping.
        vc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = vc
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) == true) {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Capture frontmost BEFORE makeKey activates us — the popover
            // view reads this for the "Throttle [frontmost]" button.
            // A live NSWorkspace query from inside the view would return
            // Air Assist itself.
            if let app = NSWorkspace.shared.frontmostApplication,
               app.processIdentifier != getpid() {
                store.capturedFrontmost = .init(pid: app.processIdentifier,
                                                name: app.localizedName ?? "Frontmost")
            } else {
                store.capturedFrontmost = nil
            }
            ensurePopoverContent()
            popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showQuickMenu() {
        guard let item = statusItem else { return }
        if popover.isShown { popover.performClose(nil) }
        quickMenu.present(on: item)
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
