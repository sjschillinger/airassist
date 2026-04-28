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

        let slot1 = store.resolveSlot(category: slot1Cat, value: slot1Val)
        let slot2 = layout == .single
            ? MenuBarSlotState.empty
            : store.resolveSlot(category: slot2Cat, value: slot2Val)
        let v1 = slot1.value
        let v2 = layout == .single ? nil : slot2.value

        // Source badge appears only on "highest" slots — that's the
        // mode where the displayed value can flip categories silently
        // ("which sensor is hottest right now?") and the badge resolves
        // the ambiguity. Average and individual already imply their
        // source. Stacked layout has no horizontal room.
        let showBadge = (defaults.object(forKey: "showMenuBarSourceBadge") as? Bool) ?? true
        let badge1: String? = (showBadge
            && layout != .stacked
            && slot1Cat == SlotCategory.highest.rawValue)
            ? slot1.sourceCategory.map(MenuBarSourceBadge.character(for:))
            : nil
        let badge2: String? = (showBadge
            && layout == .sideBySide
            && slot2Cat == SlotCategory.highest.rawValue)
            ? slot2.sourceCategory.map(MenuBarSourceBadge.character(for:))
            : nil

        // Trend glyph: only meaningful when we have history (highest or
        // individual modes — average doesn't carry one). We suppress
        // .flat in the bar so the glyph isn't a permanent fixture; the
        // eye latches onto motion, and a flat bullet sitting next to a
        // steady reading just adds noise. Suppression also lets users
        // who don't enable the badge see arrows when something is
        // actually moving.
        let showTrend = (defaults.object(forKey: "showMenuBarTrendGlyph") as? Bool) ?? true
        func trend(for state: MenuBarSlotState) -> String? {
            guard showTrend, !state.history.isEmpty,
                  let t = MenuBarTrendCompute.compute(state.history),
                  t != .flat
            else { return nil }
            return MenuBarTrendCompute.glyph(for: t)
        }
        let trend1: String? = (layout != .stacked) ? trend(for: slot1) : nil
        let trend2: String? = (layout == .sideBySide) ? trend(for: slot2) : nil

        // Width reservation for the trend glyph is decoupled from
        // whether we're actually drawing one right now. If we sized
        // the slot to the live glyph, the menu bar item would shift
        // left/right every time the temperature settled into a flat
        // band — the eye reads that as glitchy. Instead, we reserve
        // the trend's width whenever the feature is on and the slot's
        // mode can produce trends, so the slot only changes width on
        // a pref toggle, not on temperature noise.
        let reserveTrend1 = showTrend && layout != .stacked
        let reserveTrend2 = showTrend && layout == .sideBySide

        let targetLength = MenuBarIconRenderer.slotWidth(
            layout: layout,
            showIcon: showIcon,
            badge1: badge1 != nil,
            badge2: badge2 != nil,
            trend1: reserveTrend1,
            trend2: reserveTrend2
        )

        // Throttle indicator dot: red if cap is breached, orange if only
        // rules, blue ("armed") if the governor is enabled but not yet
        // doing anything. The armed dot does not pulse — it's a static
        // ready-light, not an alarm.
        let isThrottling: Bool
        let throttleDot: NSColor? = {
            if store.isPauseActive { return nil }
            if store.governor.isTempThrottling { return .systemRed }
            if store.governor.isCPUThrottling  { return .systemOrange }
            if !store.liveThrottledPIDs.isEmpty { return .systemOrange }
            if store.governorConfig.mode != .off { return .systemBlue }
            return nil
        }()
        switch throttleDot {
        case .some(.systemRed), .some(.systemOrange): isThrottling = true
        default: isThrottling = false
        }

        // Pulse only when actively throttling. Armed-but-idle stays
        // static so it doesn't draw the eye like an alarm would.
        if isThrottling {
            startPulseIfNeeded()
        } else {
            stopPulse()
        }
        let phase = isThrottling ? currentPulsePhase() : 1.0

        let rendered = MenuBarIconRenderer.render(
            layout: layout,
            v1: v1, v2: v2, unit: unit,
            sourceBadge1: badge1,
            sourceBadge2: badge2,
            trend1: trend1,
            trend2: trend2,
            reserveTrend1: reserveTrend1,
            reserveTrend2: reserveTrend2,
            iconName: iconName, tint: tint,
            showIcon: showIcon,
            throttleDot: throttleDot,
            // `liveThrottledPIDs` is the set of PIDs the throttler is
            // actively cycling right now. Governor episodes (CPU/temp
            // throttle) are conceptually "all foreground processes" but
            // don't enumerate per-PID — for those we leave the count
            // at 1 and let the dot stand in. The pill only kicks in
            // when there are genuinely multiple distinct rule/manual
            // targets being held down at once.
            throttleCount: store.liveThrottledPIDs.count,
            // Worst-case headroom drives the strip — if either visible
            // slot is creeping toward hot, that's what the user wants
            // to see. nil-safe via compactMap.
            headroom: {
                let showStrip = (defaults.object(forKey: "showMenuBarHeadroomStrip") as? Bool) ?? true
                guard showStrip else { return nil }
                let candidates = [slot1.headroom, slot2.headroom].compactMap { $0 }
                return candidates.max()
            }(),
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
            throttleDotRed: throttleDot == .systemRed,
            slot1Source: badge1 != nil ? slot1.sourceCategory : nil,
            slot2Source: badge2 != nil ? slot2.sourceCategory : nil
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
        throttleDotRed: Bool,
        slot1Source: SensorCategory? = nil,
        slot2Source: SensorCategory? = nil
    ) -> String {
        var parts: [String] = [AppStrings.appName]
        // For highest-mode slots we read the long-form category name
        // ("hottest is CPU, 84 degrees") so VoiceOver doesn't strand
        // the user trying to decode "C" as a letter. Direct slots fall
        // back to plain numbers because the user already knows what
        // they configured.
        func phrase(value: Double, source: SensorCategory?) -> String {
            let v = unit.format(value)
            if let source {
                return "hottest is \(MenuBarSourceBadge.accessibilityName(for: source)), \(v)"
            }
            return v
        }
        if let v1 {
            let p1 = phrase(value: v1, source: slot1Source)
            if let v2 {
                let p2 = phrase(value: v2, source: slot2Source)
                parts.append("\(p1), \(p2)")
            } else {
                parts.append(p1)
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
            // Mention scope when meaningful — "throttling 3 processes"
            // is materially more useful than the bare "throttling active"
            // for someone who can't see the number badge.
            let n = store.liveThrottledPIDs.count
            if n >= 2 {
                parts.append("throttling \(n) processes")
            } else {
                parts.append("throttling active")
            }
        } else if !store.liveThrottledPIDs.isEmpty {
            let n = store.liveThrottledPIDs.count
            if n >= 2 {
                parts.append("rules active on \(n) processes")
            } else {
                parts.append("rules active")
            }
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
            _ = store.governorConfig.mode
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
