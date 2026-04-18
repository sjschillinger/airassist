import Foundation

@Observable
@MainActor
final class ThermalStore {
    let sensorService = SensorService()
    var thresholds = ThresholdPersistence.load()
    private let logger = HistoryLogger()
    private var logTask: Task<Void, Never>?

    var sensors: [Sensor] { sensorService.sensors }

    var enabledSensors: [Sensor] {
        sensors.filter(\.isEnabled)
    }

    var sensorsByCategory: [(category: SensorCategory, sensors: [Sensor])] {
        let enabled = enabledSensors
        return SensorCategory.allCases.compactMap { cat in
            let group = enabled.filter { $0.category == cat }
            return group.isEmpty ? nil : (cat, group)
        }
    }

    var hottestSensor: Sensor? {
        enabledSensors
            .filter { $0.currentValue != nil }
            .max { a, b in stateRank(a) < stateRank(b) }
    }

    func start() {
        sensorService.start()
        logger.pruneOldEntries()
        logTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { break }
                self.logger.log(store: self)
            }
        }
    }

    func stop() {
        logTask?.cancel()
        logTask = nil
        sensorService.stop()
    }

    /// Resolves a temperature from the two-part slot encoding stored in UserDefaults.
    /// - category: "none" | "highest" | "average" | "individual"
    /// - value:    "overall" | "all" | SensorCategory.rawValue | sensor.id
    func temperature(category: String, value: String) -> Double? {
        switch category {
        case "highest":
            if value == "overall" { return enabledSensors.compactMap(\.currentValue).max() }
            if let cat = SensorCategory(rawValue: value) { return highestTemp(in: cat) }
            return nil
        case "average":
            if value == "all" { return averageTemp() }
            if let cat = SensorCategory(rawValue: value) { return averageTemp(in: cat) }
            return nil
        case "individual":
            return enabledSensors.first { $0.id == value }?.currentValue
        default:
            return nil
        }
    }

    func highestTemp(in category: SensorCategory) -> Double? {
        enabledSensors
            .filter { $0.category == category }
            .compactMap(\.currentValue)
            .max()
    }

    func averageTemp(in category: SensorCategory) -> Double? {
        let vals = enabledSensors.filter { $0.category == category }.compactMap(\.currentValue)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    func averageTemp() -> Double? {
        let vals = enabledSensors.compactMap(\.currentValue)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    private func stateRank(_ sensor: Sensor) -> Int {
        switch sensor.thresholdState(using: thresholds) {
        case .hot:     return 3
        case .warm:    return 2
        case .cool:    return 1
        case .unknown: return 0
        }
    }
}
