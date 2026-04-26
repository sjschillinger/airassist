import Foundation

/// User-pinned sensors. Pinned sensors sort to the top of the dashboard
/// grid and the popover sensor list, regardless of the active sort order.
///
/// Backed by UserDefaults under `sensors.favorites` as a `[String]` of
/// stable sensor IDs (the IOKit registry-ID hex string).
enum SensorFavorites {
    private static let key = "sensors.favorites"

    static func ids() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isFavorite(_ id: String) -> Bool {
        ids().contains(id)
    }

    static func toggle(_ id: String) {
        var current = ids()
        if current.contains(id) {
            current.remove(id)
        } else {
            current.insert(id)
        }
        UserDefaults.standard.set(Array(current), forKey: key)
    }
}
