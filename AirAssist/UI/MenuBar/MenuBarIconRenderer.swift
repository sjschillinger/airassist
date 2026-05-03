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
        // Each source badge is one ~9pt character + a hair of leading;
        // budgeting 11pt per badge keeps the slot from clipping while
        // staying tight enough that "C 84°" reads as one unit.
        static let badgeWidth: CGFloat            = 11
        // Font sizes at reference bar height
        static let singleFontPt: CGFloat    = 12
        static let stackedFontPt: CGFloat   = 10
        // Source-badge font: noticeably smaller than the value so the
        // eye reads the number first and the badge as a label.
        static let badgeFontPt: CGFloat     = 9
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

    /// Format a slot value according to its unit. Temperature goes
    /// through the user's chosen °C/°F formatter; percent ignores the
    /// temperature unit entirely. Centralized here so every layout
    /// branch in `render` formats consistently.
    static func formatValue(_ value: Double,
                            slotUnit: MenuBarSlotState.Unit,
                            tempUnit: TempUnit) -> String {
        switch slotUnit {
        case .temperature:
            return tempUnit.format(value)
        case .percent:
            return "\(Int(value.rounded()))%"
        }
    }

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
        /// Per-slot unit. Drives whether the value is formatted with
        /// `°C/°F` (temperature) or `%` (percent — CPU%, future
        /// memory / battery). Defaults to `.temperature` so older
        /// snapshot tests that don't pass this still compile and
        /// render the same way.
        slot1Unit: MenuBarSlotState.Unit = .temperature,
        slot2Unit: MenuBarSlotState.Unit = .temperature,
        sourceBadge1: String? = nil,
        sourceBadge2: String? = nil,
        trend1: String? = nil,
        trend2: String? = nil,
        /// When true, the trend slot reserves its layout width even
        /// when `trend1`/`trend2` is nil — by drawing an invisible
        /// placeholder glyph. Lets callers stop the menu bar item
        /// from shifting whenever the trend toggles between visible
        /// and hidden (which happens whenever the temperature settles
        /// into the flat band).
        reserveTrend1: Bool = false,
        reserveTrend2: Bool = false,
        iconName: String, tint: NSColor?,
        showIcon: Bool = true,
        throttleDot: NSColor?,
        throttleCount: Int = 0,
        headroom: Double? = nil,
        pulsePhase: CGFloat = 1.0,
        width: CGFloat
    ) -> NSImage {
        let size = NSSize(width: width, height: barHeight)
        let compositeIsTemplate = (tint == nil && throttleDot == nil && headroom == nil)
        let img = NSImage(size: size, flipped: false) { _ in
            switch layout {
            case .single:
                let textColor: NSColor = tint ?? .labelColor
                drawIconPlusAttributedText(
                    text: composeSlot(
                        value: v1.map { formatValue($0, slotUnit: slot1Unit, tempUnit: unit) } ?? "",
                        badge: sourceBadge1,
                        trend: trend1,
                        reserveTrend: reserveTrend1,
                        textColor: textColor
                    ),
                    iconName: iconName, tint: tint,
                    showIcon: showIcon,
                    throttleDot: throttleDot,
                    throttleCount: throttleCount,
                    compositeIsTemplate: compositeIsTemplate,
                    pulsePhase: pulsePhase,
                    size: size
                )
            case .sideBySide:
                let textColor: NSColor = tint ?? .labelColor
                let combined = NSMutableAttributedString()
                if let v1 {
                    combined.append(composeSlot(
                        value: formatValue(v1, slotUnit: slot1Unit, tempUnit: unit),
                        badge: sourceBadge1,
                        trend: trend1, reserveTrend: reserveTrend1,
                        textColor: textColor
                    ))
                }
                if let v2 {
                    if combined.length > 0 {
                        combined.append(NSAttributedString(
                            string: "  ",
                            attributes: [.font: slotFont(),
                                         .foregroundColor: textColor]
                        ))
                    }
                    combined.append(composeSlot(
                        value: formatValue(v2, slotUnit: slot2Unit, tempUnit: unit),
                        badge: sourceBadge2,
                        trend: trend2, reserveTrend: reserveTrend2,
                        textColor: textColor
                    ))
                }
                drawIconPlusAttributedText(
                    text: combined,
                    iconName: iconName, tint: tint,
                    showIcon: showIcon,
                    throttleDot: throttleDot,
                    throttleCount: throttleCount,
                    compositeIsTemplate: compositeIsTemplate,
                    pulsePhase: pulsePhase,
                    size: size
                )
            case .stacked:
                drawStackedText(
                    top:    v1.map { formatValue($0, slotUnit: slot1Unit, tempUnit: unit) } ?? "–",
                    bottom: v2.map { formatValue($0, slotUnit: slot2Unit, tempUnit: unit) } ?? "–",
                    size: size
                )
            }
            // Headroom strip — drawn last so it sits on top of the
            // icon's bottom edge but under nothing else. See
            // `drawHeadroomStrip` for the full design rationale.
            if let h = headroom {
                drawHeadroomStrip(headroom: h, size: size)
            }
            return true
        }
        // The strip uses systemBlue/systemOrange/systemRed which all
        // carry color, so once it's drawn the composite cannot be a
        // template. Keep the auto-template path only when there is no
        // tint AND no dot AND no headroom.
        img.isTemplate = compositeIsTemplate
        return img
    }

    /// Draws a thin progress strip across the bottom of the bar. Width
    /// is proportional to `headroom` (0…1). Color interpolates
    /// blue → orange → red so the eye picks up "creeping toward hot"
    /// well before the main tint flips.
    ///
    /// Why one strip across the whole item instead of per-slot:
    ///   - The composer treats sideBySide as a single attributed-text
    ///     block, so per-slot rects aren't easily recoverable here.
    ///   - The user cares about the worst sensor anyway — that's the
    ///     one that's going to throttle first.
    /// Caller is responsible for picking which slot's headroom to pass
    /// (typically `max(slot1.headroom, slot2.headroom)`).
    private static func drawHeadroomStrip(headroom: Double, size: NSSize) {
        let h = max(0, min(1, headroom))
        // Hide the strip entirely below ~10% so a cool Mac doesn't
        // carry a permanent low-grade tinted line at the bottom of
        // the menu bar — the strip should *appear* as the room runs
        // out, not be a fixture.
        guard h > 0.1 else { return }

        let stripHeight: CGFloat = max(1.5, 1.5 * barScale)
        // Inset 2pt on each side so the strip doesn't kiss the slot's
        // own boundary in the menu bar — leaves visual breathing room
        // next to neighbouring status items.
        let horizontalInset: CGFloat = 2
        let usableWidth = max(0, size.width - horizontalInset * 2)
        let fillWidth = usableWidth * CGFloat(h)
        let stripRect = NSRect(
            x: horizontalInset,
            y: 0.5,                         // 0.5pt off the bottom edge
            width: fillWidth,
            height: stripHeight
        )

        // Three-stop color ramp. Below 0.5 we fade blue → orange;
        // above 0.5 we fade orange → red. Alpha climbs with headroom
        // because a near-empty strip at full alpha would look like an
        // alarm; a near-full strip should read clearly.
        let stripColor: NSColor = {
            if h < 0.5 {
                let t = h / 0.5
                return blend(.systemBlue, .systemOrange, t)
                    .withAlphaComponent(0.45 + 0.25 * CGFloat(t))
            } else {
                let t = (h - 0.5) / 0.5
                return blend(.systemOrange, .systemRed, t)
                    .withAlphaComponent(0.70 + 0.20 * CGFloat(t))
            }
        }()
        stripColor.set()
        // Rounded so it doesn't read as a hard edge against the menu
        // bar's translucent background.
        NSBezierPath(roundedRect: stripRect,
                     xRadius: stripHeight / 2,
                     yRadius: stripHeight / 2).fill()
    }

    /// Linear-interpolate two NSColors in their RGB representations.
    /// `t` is clamped to 0…1.
    private static func blend(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let clamped = max(0, min(1, t))
        // Convert to a representable RGB space; system dynamic colors
        // need this dance or .redComponent traps.
        guard let aRGB = a.usingColorSpace(.deviceRGB),
              let bRGB = b.usingColorSpace(.deviceRGB) else {
            return clamped < 0.5 ? a : b
        }
        let f = CGFloat(clamped)
        return NSColor(
            deviceRed:   aRGB.redComponent   * (1 - f) + bRGB.redComponent   * f,
            green:       aRGB.greenComponent * (1 - f) + bRGB.greenComponent * f,
            blue:        aRGB.blueComponent  * (1 - f) + bRGB.blueComponent  * f,
            alpha: 1
        )
    }

    /// Width for a slot-with-badges configuration. Badges add a small
    /// fixed amount per side so the slot doesn't clip when the user
    /// has them on. Stacked layout never carries badges (no horizontal
    /// room) so it's exempt.
    static func slotWidth(
        layout: MenuBarLayout,
        showIcon: Bool,
        badge1: Bool,
        badge2: Bool,
        trend1: Bool = false,
        trend2: Bool = false
    ) -> CGFloat {
        let scale = barScale
        let badgePad = BaseSize.badgeWidth * scale
        // Trend glyph is one ~9pt arrow; same budget as the badge slot
        // is honest enough and keeps the math symmetric.
        let trendPad = BaseSize.badgeWidth * scale
        switch layout {
        case .single:
            let base = showIcon ? BaseSize.singleWidth : BaseSize.singleWidthNoIcon
            return base * scale
                + (badge1 ? badgePad : 0)
                + (trend1 ? trendPad : 0)
        case .sideBySide:
            let base = showIcon ? BaseSize.sideBySideWidth : BaseSize.sideBySideWidthNoIcon
            return base * scale
                + (badge1 ? badgePad : 0)
                + (badge2 ? badgePad : 0)
                + (trend1 ? trendPad : 0)
                + (trend2 ? trendPad : 0)
        case .stacked:
            return BaseSize.stackedWidth * scale
        }
    }

    private static func slotFont() -> NSFont {
        .monospacedDigitSystemFont(ofSize: BaseSize.singleFontPt * barScale, weight: .regular)
    }

    /// Compose "[badge ]value" as an attributed string. The badge is
    /// drawn in a smaller font and dimmer color so it reads as a label
    /// rather than competing with the value itself.
    private static func composeSlot(
        value: String, badge: String?,
        trend: String? = nil, reserveTrend: Bool = false,
        textColor: NSColor
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let valueFont = slotFont()
        let supportFont: NSFont = .systemFont(
            ofSize: BaseSize.badgeFontPt * barScale, weight: .semibold
        )
        // 0.65 alpha gives the eye a clear hierarchy: value dominant,
        // supporting glyphs softer. Inherits the slot's tint so warm/hot
        // states don't lose their color signal.
        let supportColor = textColor.withAlphaComponent(0.65)

        if let badge, !badge.isEmpty {
            // Hair-space separator (\u{2009}) keeps "C84°" from collapsing
            // visually — wide enough to read as separate, tighter than a
            // full space which would push the value out of frame.
            out.append(NSAttributedString(
                string: badge + "\u{2009}",
                attributes: [.font: supportFont, .foregroundColor: supportColor]
            ))
        }
        out.append(NSAttributedString(
            string: value,
            attributes: [.font: valueFont, .foregroundColor: textColor]
        ))
        if let trend, !trend.isEmpty {
            // Trend glyph trails the value with another hair-space —
            // the eye reads "84°↑" as one chunk. Subtle on purpose:
            // direction is supporting info, not a primary signal.
            out.append(NSAttributedString(
                string: "\u{2009}" + trend,
                attributes: [.font: supportFont, .foregroundColor: supportColor]
            ))
        } else if reserveTrend {
            // No live arrow but the caller wants the slot's width
            // pinned. Draw an arrow with alpha 0 so the layout is
            // identical to the visible-arrow case — eliminates the
            // left/right wobble that happens whenever the temperature
            // settles into the flat band and the arrow vanishes.
            out.append(NSAttributedString(
                string: "\u{2009}↑",
                attributes: [.font: supportFont,
                             .foregroundColor: NSColor.clear]
            ))
        }
        return out
    }

    // MARK: - Private drawing primitives

    private static func drawIconPlusAttributedText(
        text: NSAttributedString, iconName: String, tint: NSColor?,
        showIcon: Bool = true,
        throttleDot: NSColor?,
        throttleCount: Int = 0,
        compositeIsTemplate: Bool = true,
        pulsePhase: CGFloat = 1.0,
        size: NSSize
    ) {
        let scale = barScale
        // Prefer the custom AirAssist glyph asset (template-rendered, so macOS
        // auto-flips black/white with menu-bar appearance). Fall back to the
        // SF Symbol name for robustness if the asset ever goes missing.
        let targetPt = BaseSize.iconPt * scale
        // The tight-cropped menu-bar glyph still has a touch of margin inside
        // its viewBox, so draw it a bit larger than the SF-Symbol baseline to
        // match the visual weight of neighbouring system icons.
        let glyphScale: CGFloat = 1.35
        let baseIcon: NSImage? = {
            guard showIcon else { return nil }
            if let glyph = NSImage(named: "MenuBarGlyph") {
                // Template imagesets return isTemplate = true via asset metadata;
                // belt-and-braces for external callers.
                glyph.isTemplate = true
                let drawPt = targetPt * glyphScale
                let resized = NSImage(size: NSSize(width: drawPt, height: drawPt))
                resized.isTemplate = true
                resized.lockFocus()
                glyph.draw(in: NSRect(x: 0, y: 0, width: drawPt, height: drawPt),
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
        let textSize = text.size()
        let textIsEmpty = (text.length == 0)

        let gap: CGFloat = 3
        let iconBlockWidth: CGFloat = showIcon ? iconSize.width : 0
        let joinGap: CGFloat = (showIcon && !textIsEmpty) ? gap : 0
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
            // The composite image will lose `isTemplate` as soon as any colored
            // element (thermal tint OR throttle dot) is baked in, which means
            // macOS won't auto-flip black→white when the menu bar appearance
            // changes. In that case we must manually draw the glyph in the
            // current labelColor. When no coloured element is present we leave
            // the glyph as pure black and let the template flip in the status
            // bar handle it.
            // The caller knows the full set of color-bearing elements
            // (tint, throttle dot, headroom strip) and tells us whether
            // the composite will retain template behaviour. When it
            // won't, we have to manually paint the glyph in labelColor
            // because macOS won't auto-flip black→white for us.
            let effectiveColor: NSColor? = tint ?? (compositeIsTemplate ? nil : NSColor.labelColor)
            if let color = effectiveColor {
                color.set()
                let tinted = baseIcon.copy() as! NSImage
                tinted.isTemplate = false
                tinted.lockFocus()
                color.set()
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
        if !textIsEmpty {
            textRect = NSRect(
                x: startX + iconBlockWidth + joinGap,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect)
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
            } else if !textIsEmpty {
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

            // When more than one process is currently throttled, the
            // bare dot under-reports. We bump the dot to a small
            // numeric badge ("2", "3", … capped at "9+") so the user
            // can see scope at a glance — five throttled processes
            // looks materially different from one. Single-process and
            // zero-but-armed states keep the existing dot, because
            // labelling a "1" badge would be more visual noise than
            // signal.
            if throttleCount >= 2 {
                let label = throttleCount > 9 ? "9+" : "\(throttleCount)"
                let badgeFont: NSFont = .monospacedDigitSystemFont(
                    ofSize: BaseSize.badgeFontPt * scale, weight: .bold
                )
                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: badgeFont,
                    .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                ]
                let labelSize = (label as NSString).size(withAttributes: labelAttrs)
                // The badge is a pill sized to fit the label with 1.5pt
                // horizontal padding. Height matches the dot's intended
                // diameter so vertical alignment in the bar stays stable.
                let pillHeight = max(dotDiameter + 2, labelSize.height + 1)
                let pillWidth  = max(pillHeight, labelSize.width + 4)
                let pillRect = NSRect(
                    x: dotRect.midX - pillWidth / 2,
                    y: dotRect.midY - pillHeight / 2,
                    width: pillWidth,
                    height: pillHeight
                )
                let radius = pillHeight / 2
                NSColor.windowBackgroundColor.withAlphaComponent(0.6 * alpha).set()
                NSBezierPath(roundedRect: pillRect.insetBy(dx: -0.8, dy: -0.8),
                             xRadius: radius + 0.8,
                             yRadius: radius + 0.8).fill()
                dotColor.withAlphaComponent(alpha).set()
                NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius).fill()
                let labelOrigin = NSPoint(
                    x: pillRect.midX - labelSize.width / 2,
                    y: pillRect.midY - labelSize.height / 2 + 0.5
                )
                (label as NSString).draw(at: labelOrigin, withAttributes: labelAttrs)
            } else {
                NSColor.windowBackgroundColor.withAlphaComponent(0.6 * alpha).set()
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.8, dy: -0.8)).fill()
                dotColor.withAlphaComponent(alpha).set()
                NSBezierPath(ovalIn: dotRect).fill()
            }
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
