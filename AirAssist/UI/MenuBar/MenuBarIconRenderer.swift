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
        static let singleWidth: CGFloat     = 56
        static let sideBySideWidth: CGFloat = 86
        static let stackedWidth: CGFloat    = 44
        // Font sizes at reference bar height
        static let singleFontPt: CGFloat    = 12
        static let stackedFontPt: CGFloat   = 10
        static let iconPt: CGFloat          = 13
    }

    /// Scale factor vs. the 22pt reference menu bar.
    static var barScale: CGFloat {
        max(1.0, NSStatusBar.system.thickness / BaseSize.referenceBarHeight)
    }
    static var widthSingle: CGFloat     { BaseSize.singleWidth * barScale }
    static var widthSideBySide: CGFloat { BaseSize.sideBySideWidth * barScale }
    static var widthStacked: CGFloat    { BaseSize.stackedWidth * barScale }

    static var barHeight: CGFloat { NSStatusBar.system.thickness }

    /// Produce the complete status-item image for the given layout & state.
    /// Auto-template mode is on unless a tint or throttle dot would be lost
    /// under system tinting.
    static func render(
        layout: MenuBarLayout,
        v1: Double?, v2: Double?, unit: TempUnit,
        iconName: String, tint: NSColor?,
        throttleDot: NSColor?,
        width: CGFloat
    ) -> NSImage {
        let size = NSSize(width: width, height: barHeight)
        let img = NSImage(size: size, flipped: false) { _ in
            switch layout {
            case .single:
                drawIconPlusText(
                    text: v1.map(unit.format) ?? "",
                    iconName: iconName, tint: tint,
                    throttleDot: throttleDot,
                    size: size
                )
            case .sideBySide:
                var parts: [String] = []
                if let v1 { parts.append(unit.format(v1)) }
                if let v2 { parts.append(unit.format(v2)) }
                drawIconPlusText(
                    text: parts.joined(separator: "  "),
                    iconName: iconName, tint: tint,
                    throttleDot: throttleDot,
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
        throttleDot: NSColor?,
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

        // Throttle dot
        if let dotColor = throttleDot {
            let dotDiameter: CGFloat = max(4, BaseSize.iconPt * scale * 0.38)
            let dotRect = NSRect(
                x: iconRect.maxX - dotDiameter * 0.9,
                y: iconRect.minY - dotDiameter * 0.15,
                width: dotDiameter,
                height: dotDiameter
            )
            NSColor.windowBackgroundColor.withAlphaComponent(0.6).set()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.8, dy: -0.8)).fill()
            dotColor.set()
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
