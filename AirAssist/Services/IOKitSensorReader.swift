import Foundation

struct SensorReading: Sendable {
    let id: String       // stable: registry ID as hex string
    let name: String     // raw IOKit product string
    let value: Double    // Celsius
}

// All IOKit C-API calls are isolated here. Nothing outside this file touches IOKit directly.
enum IOKitSensorReader {
    // IOHIDEventTypeTemperature = 15; field = (type << 16) | index
    private static let kTempEventType: Int64 = 15
    private static let kTempField: Int32     = 15 << 16

    // Apple Silicon thermal sensor matching criteria
    private static let kUsagePage: Int = 0xff00
    private static let kUsage: Int     = 0x0005

    // Box keeps CFTypeRef sendable across actor/thread boundaries.
    // Written once at setup() on the main thread; read-only afterwards.
    // Both the parent client AND the services array are cached: each
    // IOHIDServiceClient in the array holds its own XPC user-client connection,
    // so releasing & re-fetching per poll would tear those down every cycle
    // and log "[C:1] Error received: Connection interrupted."
    private final class ClientBox: @unchecked Sendable {
        var client: CFTypeRef?
        var services: CFArray?
    }
    private static let box = ClientBox()

    /// Plausible temperature range for any AirAssist-tracked sensor.
    /// Apple Silicon SMC / HID sensors read in Celsius; anything outside
    /// this window is a driver hiccup, a NaN-propagating garbage read, or
    /// a sensor that's physically impossible for a consumer Mac (LN2
    /// cooling, datacenter failure). Filtering at the source prevents
    /// these poison values from ever reaching the governor's comparisons,
    /// the sparkline's min/max, or the on-disk history.
    private static let minPlausibleC: Double = -20.0
    private static let maxPlausibleC: Double = 125.0

    /// Call once at app startup (from SensorService.start) to create the persistent
    /// IOHIDEventSystemClient. Keeping a single long-lived client avoids the
    /// "[C:1] Error received: Connection interrupted." XPC noise that occurs when
    /// a new client is created and destroyed on every poll cycle.
    ///
    /// Note: `as!` to CoreFoundation types is compile-time-guaranteed by the
    /// Swift compiler (CFTypeRef bridging to the concrete CF type is total),
    /// so there is no runtime failure surface here. The real resilience
    /// lives in `readAllSensors` where individual readings are filtered for
    /// NaN/Inf/out-of-range before being returned.
    static func setup() {
        guard box.client == nil,
              let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        let matching: CFArray = [["PrimaryUsagePage": kUsagePage,
                                  "PrimaryUsage":     kUsage] as CFDictionary] as CFArray
        IOHIDEventSystemClientSetMatchingMultiple(client, matching)
        box.client = client
        box.services = IOHIDEventSystemClientCopyServices(client as! IOHIDEventSystemClient)
    }

    static func readAllSensors() -> [SensorReading] {
        guard box.client != nil, let services = box.services else { return [] }

        var readings: [SensorReading] = []
        let count = CFArrayGetCount(services)

        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(services, i) else { continue }
            let service: AnyObject = unsafeBitCast(rawPtr, to: AnyObject.self)
            let typedService = service as! IOHIDServiceClient

            guard let nameRef = IOHIDServiceClientCopyProperty(typedService, "Product" as CFString),
                  let name = nameRef as? String else { continue }

            guard let event = IOHIDServiceClientCopyEvent(service, kTempEventType, 0, 0) else { continue }
            let tempC = IOHIDEventGetFloatValue(event, kTempField)

            // Reject NaN / Inf / obviously-wrong values at the source. A
            // NaN reading passed through to the governor's comparisons
            // would silently evaluate every threshold to false (NaN > x
            // is always false) — the thermal protection just stops
            // working. Better to drop the reading and let the sensor
            // recover next poll.
            guard tempC.isFinite,
                  tempC >= minPlausibleC,
                  tempC <= maxPlausibleC else { continue }

            let registryID = AirAssist_IOHIDServiceClientGetRegistryID(service)
            let id = String(format: "%016llx", registryID)
            readings.append(SensorReading(id: id, name: name, value: tempC))
        }

        return readings.sorted { $0.name < $1.name }
    }
}
