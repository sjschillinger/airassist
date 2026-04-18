import Foundation

@Observable
@MainActor
final class SensorService {
    private(set) var sensors: [Sensor] = []
    var pollIntervalSeconds: Double = 1.0
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        IOKitSensorReader.setup()          // create persistent IOHIDEventSystemClient once
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let readings = IOKitSensorReader.readAllSensors()
                await self?.reconcile(readings: readings)
                let interval = await self?.pollIntervalSeconds ?? 2.0
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func reconcile(readings: [SensorReading]) {
        var index = Dictionary(uniqueKeysWithValues: sensors.map { ($0.id, $0) })

        for reading in readings {
            if let existing = index[reading.id] {
                existing.currentValue = reading.value
                existing.pushHistory(reading.value)
            } else {
                let sensor = Sensor(
                    id: reading.id,
                    rawName: reading.name,
                    category: SensorCategorizer.category(for: reading.name)
                )
                sensor.currentValue = reading.value
                sensor.pushHistory(reading.value)
                sensor.isEnabled = SensorEnabledPersistence.isEnabled(sensorID: reading.id)
                sensors.append(sensor)
                index[sensor.id] = sensor
            }
        }
    }
}
