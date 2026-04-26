import Foundation

/// User-managed "never throttle these apps" list.
///
/// This is the strong, user-explicit form of `ProcessInspector.excludedNames`
/// (which is a built-in convenience allowlist for system + dev tools). Apps
/// listed here are rejected by `ProcessThrottler.setDuty` regardless of
/// source — including manual clicks. The semantics: the user has *deliberately*
/// said "never touch this," so even an explicit user click should bounce
/// rather than silently ignore the list.
///
/// Stored as a `[String]` of executable names in UserDefaults under
/// `neverThrottleNames`. Names match the same form ProcessInspector reports
/// (case-sensitive executable name).
///
/// Membership lookups go through `contains(_:)` — that bridges from
/// UserDefaults on every call (cheap, ≤ a few dozen entries) so writes from
/// the prefs UI take effect immediately without a notification round-trip.
enum NeverThrottleList {

    private static let key = "neverThrottleNames"

    /// Current list, sorted case-insensitively for stable UI display.
    static func names() -> [String] {
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return raw.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Fast membership check used by `ProcessThrottler.setDuty`.
    static func contains(_ name: String) -> Bool {
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return raw.contains(name)
    }

    static func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !current.contains(trimmed) else { return }
        current.append(trimmed)
        UserDefaults.standard.set(current, forKey: key)
    }

    static func remove(_ name: String) {
        var current = UserDefaults.standard.stringArray(forKey: key) ?? []
        current.removeAll { $0 == name }
        UserDefaults.standard.set(current, forKey: key)
    }
}
