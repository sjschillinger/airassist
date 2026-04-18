import Foundation

@Observable
@MainActor
final class SensorService {
    private(set) var sensors: [Sensor] = []
    var pollIntervalSeconds: Double = 1.0
    private var pollTask: Task<Void, Never>?

    /// Wall-clock time of the start() call, nil before start / after stop.
    /// Used by the UI to distinguish "still booting" from "genuinely failed."
    private(set) var startedAt: Date?

    /// True once we've attempted at least one read, regardless of result.
    /// Lets the UI show a spinner until the first poll completes.
    private(set) var hasAttemptedRead: Bool = false

    /// Best-effort read-state for the UI:
    ///   - `.booting`: service just started, first read hasn't completed
    ///   - `.ok`: we have one or more sensors
    ///   - `.unavailable`: we've been running for >5s, polled at least once,
    ///                    and IOHIDEventSystemClient returned zero sensors.
    ///                    Usually means the entitlement is missing (debug
    ///                    builds from DerivedData on macOS 15+), an OS
    ///                    change broke the API, or the hardware isn't
    ///                    exposing its thermal HID services.
    enum ReadState { case booting, ok, unavailable }
    var readState: ReadState {
        if !sensors.isEmpty { return .ok }
        guard let startedAt, hasAttemptedRead else { return .booting }
        return Date().timeIntervalSince(startedAt) > 5 ? .unavailable : .booting
    }

    func start() {
        guard pollTask == nil else { return }
        IOKitSensorReader.setup()          // create persistent IOHIDEventSystemClient once
        startedAt = Date()
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let readings = IOKitSensorReader.readAllSensors()
                await self?.reconcile(readings: readings)
                await self?.markAttempted()
                let interval = await self?.pollIntervalSeconds ?? 2.0
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func markAttempted() {
        hasAttemptedRead = true
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        startedAt = nil
        hasAttemptedRead = false
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
