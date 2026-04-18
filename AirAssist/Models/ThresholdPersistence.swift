import Foundation

enum ThresholdPersistence {
    private static let key = "com.sjschillinger.airassist.thresholds"

    static func load() -> ThresholdSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ThresholdSettings.self, from: data)
        else { return ThresholdSettings() }
        return decoded
    }

    static func save(_ settings: ThresholdSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum SensorEnabledPersistence {
    static func isEnabled(sensorID: String) -> Bool {
        let key = "sensor.enabled.\(sensorID)"
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, sensorID: String) {
        UserDefaults.standard.set(enabled, forKey: "sensor.enabled.\(sensorID)")
    }
}
