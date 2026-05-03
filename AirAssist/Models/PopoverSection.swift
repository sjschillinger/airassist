import Foundation

/// Identifiers for the customizable sections of the menu-bar popover.
///
/// Used by the popover view to gate visibility (Phase 2 of the
/// visibility sprint) and by the future Preferences UI (Phase 5)
/// that lets the user pick which sections appear.
///
/// Two sections of the popover are deliberately *not* customizable:
///   - the header (app name + pause menu) — always visible
///   - the action buttons (Dashboard / Preferences / Quit) — always visible
///
/// These are the popover's anchor UI; without them the user can't
/// reach Preferences to re-show what they hid.
///
/// Granularity is intentionally coarser than the underlying view
/// structure — e.g. `sensors` covers both the sensor grid and the
/// sparkline below it. We can split sections in a later release if
/// users ask.
enum PopoverSection: String, CaseIterable, Codable, Identifiable {
    /// Sensor grid + the live trend sparkline below it.
    case sensors

    /// "CPU Activity" panel showing the live top-N processes.
    case cpuActivity

    /// Strip listing PIDs the user manually threw under the bus
    /// via "Throttle [frontmost]" or the URL scheme.
    case manualThrottles

    /// Governor status line + active throttle rows from rules /
    /// the governor.
    case governorStatus

    /// Bottom controls block: governor master toggle, scenarios,
    /// stay-awake quick picker, on-battery toggle, etc.
    case controls

    var id: String { rawValue }

    /// User-facing label for the Preferences UI in Phase 5.
    var label: String {
        switch self {
        case .sensors:           return "Sensors"
        case .cpuActivity:       return "CPU Activity"
        case .manualThrottles:   return "Manual throttles"
        case .governorStatus:    return "Governor status"
        case .controls:          return "Controls"
        }
    }

    /// Long-form help text for the Preferences info popover.
    var helpDescription: String {
        switch self {
        case .sensors:
            return "The grid of sensor cards plus the live trend sparkline. Hide if you only want the popover for controls and don't need the at-a-glance temperature view."
        case .cpuActivity:
            return "Top 5 processes by CPU usage right now, with a right-click menu to throttle, rule, or protect. Hide if you'd rather rely on the dashboard for process visibility."
        case .manualThrottles:
            return "List of processes you've manually thrown a cap on, with their remaining time. Always hidden when nothing's manually throttled, so most of the time leaving this on is invisible."
        case .governorStatus:
            return "Status line for the automatic governor (armed / throttling / paused) and a list of any active rule- or governor-driven throttles. Hide if you don't use automatic throttling."
        case .controls:
            return "The block at the bottom with the governor toggle, scenario picker, stay-awake mode, and the on-battery-only switch. Hide if you only configure these from Preferences."
        }
    }

    /// SF Symbol used in the Preferences row in Phase 5.
    var sfSymbol: String {
        switch self {
        case .sensors:           return "thermometer.medium"
        case .cpuActivity:       return "cpu"
        case .manualThrottles:   return "tortoise.fill"
        case .governorStatus:    return "gauge.with.dots.needle.67percent"
        case .controls:          return "slider.horizontal.3"
        }
    }
}

/// Persistence helpers for popover-section ordering and visibility.
///
/// Two storage keys, two independent concerns:
///   - **order** — a list of *all* sections in the user's preferred
///     display order. Defaults to canonical (`PopoverSection.allCases`).
///   - **hidden** — a set of sections the user has turned off.
///     Defaults to empty (everything visible).
///
/// Splitting them this way keeps each operation honest about what
/// it changes:
///   - `setVisible(.X, false)` only touches the hidden set;
///     order is preserved.
///   - `reorder([...])` only touches the order; hidden status is
///     preserved.
///
/// Forward-compatible: when a future release adds a new section,
/// `currentOrder()` merges any unknown cases onto the end so users
/// don't lose access. Backward-compatible: removed cases (if we ever
/// drop one) are silently filtered out via `compactMap`.
enum PopoverSectionPrefs {
    /// `UserDefaults` key for the ordered list of all sections.
    /// Stored as a JSON-encoded `[String]` of raw values so we
    /// survive enum case changes between releases without throwing.
    static let orderKey = "popover.sections.order"

    /// `UserDefaults` key for the set of hidden sections.
    /// JSON-encoded `[String]` of raw values.
    static let hiddenKey = "popover.sections.hidden"

    /// All sections in the user's preferred display order.
    /// Defaults to `PopoverSection.allCases` if nothing's saved.
    static func currentOrder(defaults: UserDefaults = .standard) -> [PopoverSection] {
        let saved = decode(key: orderKey, defaults: defaults)
        guard let saved else { return PopoverSection.allCases }
        return mergeUnknowns(into: saved)
    }

    /// The set of sections the user has hidden. Defaults to empty.
    static func hiddenSet(defaults: UserDefaults = .standard) -> Set<PopoverSection> {
        let decoded = decode(key: hiddenKey, defaults: defaults) ?? []
        return Set(decoded)
    }

    /// Whether a given section should be rendered. The popover view
    /// calls this once per section per render.
    static func isVisible(_ section: PopoverSection,
                          defaults: UserDefaults = .standard) -> Bool {
        !hiddenSet(defaults: defaults).contains(section)
    }

    /// Visible sections in the user's preferred order. Phase 5+ may
    /// use this for full ordered iteration; Phase 2 uses `isVisible`
    /// against fixed-order body code.
    static func visibleOrdered(defaults: UserDefaults = .standard) -> [PopoverSection] {
        let order = currentOrder(defaults: defaults)
        let hidden = hiddenSet(defaults: defaults)
        return order.filter { !hidden.contains($0) }
    }

    /// Show or hide a section. Order is preserved.
    static func setVisible(_ section: PopoverSection,
                           _ visible: Bool,
                           defaults: UserDefaults = .standard) {
        var hidden = hiddenSet(defaults: defaults)
        if visible {
            hidden.remove(section)
        } else {
            hidden.insert(section)
        }
        save(Array(hidden), key: hiddenKey, defaults: defaults)
    }

    /// Replace the order entirely. Visibility is unchanged.
    /// Phase 5+ when drag-to-reorder lands.
    static func reorder(_ ordered: [PopoverSection],
                        defaults: UserDefaults = .standard) {
        save(mergeUnknowns(into: ordered), key: orderKey, defaults: defaults)
    }

    /// Wipe both keys back to canonical defaults. Useful for the
    /// eventual Preferences "Restore defaults" button.
    static func resetToDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: orderKey)
        defaults.removeObject(forKey: hiddenKey)
    }

    // MARK: - Private

    /// Append any `allCases` entries that aren't in `saved`. Keeps
    /// upgrade paths painless: a new release with a new section
    /// surfaces it at the end of every existing user's popover, so
    /// nobody has to know to go re-enable it.
    private static func mergeUnknowns(into saved: [PopoverSection]) -> [PopoverSection] {
        var result = saved
        for c in PopoverSection.allCases where !result.contains(c) {
            result.append(c)
        }
        return result
    }

    /// Decode a persisted list. Returns `nil` if no value, JSON is
    /// malformed, or every entry is unknown. compactMap silently
    /// drops unknown raw values (forward / backward compatibility).
    private static func decode(key: String, defaults: UserDefaults) -> [PopoverSection]? {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let stringArray = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return stringArray.compactMap { PopoverSection(rawValue: $0) }
    }

    private static func save(_ ordered: [PopoverSection], key: String, defaults: UserDefaults) {
        let strings = ordered.map(\.rawValue)
        guard let data = try? JSONEncoder().encode(strings),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: key)
    }
}
