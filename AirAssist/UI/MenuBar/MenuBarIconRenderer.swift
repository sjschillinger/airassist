import AppKit

/// Off-screen rendering for the menu bar button. Produces a single NSImage
/// sized exactly to the status item — NSButtonCell vertically centers
/// images by default so this gives pixel-accurate centering across all
/// layouts without per-poll mutation of imagePosition/attributedTitle
/// (which increases cross-process size churn against ControlCenter).
///
/// Extracted from `MenuBarController` to keep the controller focused on
/// coordination; nothing in here touches `ThermalStore` state directly.
enum MenuBarIconRenderer {

    // Base widths & font sizes, calibrated for the standard 22pt menu bar.
    // On displays with a taller bar (macOS HiDPI scaling / accessibility),
    // both slot width and font scale proportionally so content fills the
    // bar at the same visual density.
    enum BaseSize {
        static let referenceBarHeight: CGFloat = 22
        // Slot widths at reference bar height
        static let singleWidth: CGFloat           = 56
        static let singleWidthNoIcon: CGFloat     = 40
        static let sideBySideWidth: CGFloat       = 86
        static let sideBySideWidthNoIcon: CGFloat = 70
        static let stackedWidth: CGFloat          = 44
        // Font sizes at reference bar height
        static let singleFontPt: CGFloat    = 12
        static let stackedFontPt: CGFloat   = 10
        static let iconPt: CGFloat          = 13
    }

    /// Scale factor vs. the 22pt reference menu bar.
    static var barScale: CGFloat {
        max(1.0, NSStatusBar.system.thickness / BaseSize.referenceBarHeight)
    }
    static var widthSingle: CGFloat            { BaseSize.singleWidth * barScale }
    static var widthSingleNoIcon: CGFloat      { BaseSize.singleWidthNoIcon * barScale }
    static var widthSideBySide: CGFloat        { BaseSize.sideBySideWidth * barScale }
    static var widthSideBySideNoIcon: CGFloat  { BaseSize.sideBySideWidthNoIcon * barScale }
    static var widthStacked: CGFloat           { BaseSize.stackedWidth * barScale }

    static var barHeight: CGFloat { NSStatusBar.system.thickness }

    /// Minimum alpha of the heartbeat pulse at phase=0. 0.35 is low enough
    /// to read as a fade but high enough that the dot never fully vanishes
    /// (so the user doesn't think throttling just stopped).
    static let pulseMinAlpha: CGFloat = 0.35

    /// Produce the complete status-item image for the given layout & state.
    /// Auto-template mode is on unless a tint or throttle dot would be lost
    /// under system tinting.
    /// Render the complete status-item image.
    /// - Parameter pulsePhase: 0.0…1.0. Used only by the throttle dot: its
    ///   alpha is modulated between `pulseMinAlpha` and 1.0 via a raised-
    ///   sine curve so the dot slowly breathes while throttling is active.
    ///   Pass 1.0 for a static dot (no animation).
    static func render(
        layout: MenuBarLayout,
        v1: Double?, v2: Double?, unit: TempUnit,
        iconName: String, tint: NSColor?,
        showIcon: Bool = true,
        throttleDot: NSColor?,
        pulsePhase: CGFloat = 1.0,
        width: CGFloat
    ) -> NSImage {
        let size = NSSize(width: width, height: barHeight)
        let img = NSImage(size: size, flipped: false) { _ in
            switch layout {
            case .single:
                drawIconPlusText(
                    text: v1.map(unit.format) ?? "",
                    iconName: iconName, tint: tint,
                    showIcon: showIcon,
                    throttleDot: throttleDot,
                    pulsePhase: pulsePhase,
                    size: size
                )
            case .sideBySide:
                var parts: [String] = []
                if let v1 { parts.append(unit.format(v1)) }
                if let v2 { parts.append(unit.format(v2)) }
                drawIconPlusText(
                    text: parts.joined(separator: "  "),
                    iconName: iconName, tint: tint,
                    showIcon: showIcon,
                    throttleDot: throttleDot,
                    pulsePhase: pulsePhase,
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
        img.isTemplate = (tint == nil && throttleDot == nil)
        return img
    }

    // MARK: - Private drawing primitives

    private static func drawIconPlusText(
        text: String, iconName: String, tint: NSColor?,
        showIcon: Bool = true,
        throttleDot: NSColor?,
        pulsePhase: CGFloat = 1.0,
        size: NSSize
    ) {
        let scale = barScale
        // Prefer the custom AirAssist glyph asset (template-rendered, so macOS
        // auto-flips black/white with menu-bar appearance). Fall back to the
        // SF Symbol name for robustness if the asset ever goes missing.
        let targetPt = BaseSize.iconPt * scale
        let baseIcon: NSImage? = {
            guard showIcon else { return nil }
            if let glyph = NSImage(named: "MenuBarGlyph") {
                // Template imagesets return isTemplate = true via asset metadata;
                // belt-and-braces for external callers.
                glyph.isTemplate = true
                // Size to match SF Symbol rendering at the same point size.
                let resized = NSImage(size: NSSize(width: targetPt, height: targetPt))
                resized.isTemplate = true
                resized.lockFocus()
                glyph.draw(in: NSRect(x: 0, y: 0, width: targetPt, height: targetPt),
                           from: .zero, operation: .sourceOver, fraction: 1.0)
                resized.unlockFocus()
                return resized
            }
            let iconConfig = NSImage.SymbolConfiguration(pointSize: targetPt, weight: .regular)
            return NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(iconConfig)
        }()
        // If the user asked for the icon but both asset and SF Symbol failed,
        // abort — matches the old guard's behaviour. When showIcon is false,
        // baseIcon is intentionally nil and we proceed text-only.
        if showIcon && baseIcon == nil { return }
        let iconSize: NSSize = baseIcon?.size ?? .zero
        let font: NSFont = .monospacedDigitSystemFont(ofSize: BaseSize.singleFontPt * scale, weight: .regular)
        let textColor: NSColor = tint ?? .labelColor
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: textAttrs)

        let gap: CGFloat = 3
        let iconBlockWidth: CGFloat = showIcon ? iconSize.width : 0
        let joinGap: CGFloat = (showIcon && !text.isEmpty) ? gap : 0
        let totalWidth = iconBlockWidth + joinGap + textSize.width
        let startX = (size.width - totalWidth) / 2

        // Icon
        let iconRect = NSRect(
            x: startX,
            y: (size.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        if showIcon, let baseIcon {
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
                baseIcon.draw(in: iconRect)
            }
        }

        // Text
        var textRect: NSRect = .zero
        if !text.isEmpty {
            textRect = NSRect(
                x: startX + iconBlockWidth + joinGap,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: textAttrs)
        }

        // Throttle dot — pulsePhase 0→1 maps to alpha pulseMinAlpha→1.0
        // via a raised-sine so the dot breathes smoothly. Anchored to the
        // icon when visible; otherwise pinned to the trailing edge of the
        // text so throttling stays legible when the icon is hidden.
        if let dotColor = throttleDot {
            let dotDiameter: CGFloat = max(4, BaseSize.iconPt * scale * 0.38)
            let anchorMaxX: CGFloat
            let anchorMinY: CGFloat
            if showIcon {
                anchorMaxX = iconRect.maxX
                anchorMinY = iconRect.minY
            } else if !text.isEmpty {
                anchorMaxX = textRect.maxX + dotDiameter * 0.4
                anchorMinY = textRect.minY
            } else {
                anchorMaxX = size.width / 2 + dotDiameter / 2
                anchorMinY = (size.height - dotDiameter) / 2
            }
            let dotRect = NSRect(
                x: anchorMaxX - dotDiameter * 0.9,
                y: anchorMinY - dotDiameter * 0.15,
                width: dotDiameter,
                height: dotDiameter
            )
            let alpha = pulseMinAlpha + (1.0 - pulseMinAlpha) * max(0, min(1, pulsePhase))
            NSColor.windowBackgroundColor.withAlphaComponent(0.6 * alpha).set()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.8, dy: -0.8)).fill()
            dotColor.withAlphaComponent(alpha).set()
            NSBezierPath(ovalIn: dotRect).fill()
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
}
