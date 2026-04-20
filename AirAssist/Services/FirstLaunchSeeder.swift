import Foundation

/// Runs once on first launch (and quietly no-ops forever after) to make the
/// default sensor list usable instead of a wall of 14× `CPU Die N` rows +
/// PMIC noise. The user can re-enable anything in Preferences → Sensors.
///
/// Design rule: we never change *throttling* defaults here. The thermal
/// governor stays off by default — throttling user processes on first
/// launch without an explicit opt-in would be a surprising default for
/// an OSS utility.
@MainActor
enum FirstLaunchSeeder {
    /// Bumped when the seeding rules change. Lets us re-run the seed on an
    /// existing install without clobbering deliberate user changes: each
    /// version of the seed only runs once.
    private static let seedVersion = 1
    private static let seedKey = "firstLaunchSeed.version"

    /// Call after sensors have been discovered at least once. Cheap: early-
    /// returns if this version of the seed has already run.
    static func seedIfNeeded(sensors: [Sensor]) {
        let current = UserDefaults.standard.integer(forKey: seedKey)
        guard current < seedVersion else { return }
        guard !sensors.isEmpty else { return }

        for sensor in sensors {
            let enabled = defaultEnabled(for: sensor)
            SensorEnabledPersistence.setEnabled(enabled, sensorID: sensor.id)
            sensor.isEnabled = enabled
        }

        UserDefaults.standard.set(seedVersion, forKey: seedKey)
    }

    /// Heuristic for which sensors are worth showing by default. Honest
    /// tradeoff: the full sensor zoo is visible in Preferences → Sensors
    /// for anyone who wants to see everything.
    private static func defaultEnabled(for sensor: Sensor) -> Bool {
        // Always-on: a single-sensor category is never noise.
        switch sensor.category {
        case .battery, .gpu, .storage:
            return true
        case .soc:
            return true
        case .cpu:
            // CPU Die 1..4 are representative; 5..14 repeat the same
            // physical cluster info and bloat the popover.
            return !isHighIndexCPUDie(sensor.displayName)
        case .other:
            // "Other" tends to be PMIC / ambient rails the user can't act
            // on. Hidden by default; available behind Preferences.
            return false
        }
    }

    /// Matches "CPU Die 5", "CPU Die 14", etc. Returns true only for index
    /// >= 5 so the first four dies remain visible on Pro/Max parts.
    private static func isHighIndexCPUDie(_ name: String) -> Bool {
        // Fast reject: skip the regex unless the name looks plausible.
        guard name.hasPrefix("CPU Die ") else { return false }
        let suffix = name.dropFirst("CPU Die ".count)
        guard let n = Int(suffix) else { return false }
        return n >= 5
    }
}
