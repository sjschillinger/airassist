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

    /// Call once at app startup (from SensorService.start) to create the persistent
    /// IOHIDEventSystemClient. Keeping a single long-lived client avoids the
    /// "[C:1] Error received: Connection interrupted." XPC noise that occurs when
    /// a new client is created and destroyed on every poll cycle.
    static func setup() {
        guard box.client == nil,
              let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        let matching: CFArray = [["PrimaryUsagePage": kUsagePage,
                                  "PrimaryUsage":     kUsage] as CFDictionary] as CFArray
        IOHIDEventSystemClientSetMatchingMultiple(client, matching)
        box.client = client
        // Fetch services once — each holds a long-lived IOKit user-client connection.
        // We reuse the same service refs on every poll to avoid XPC teardown spam.
        // SDK 15 exposes IOHIDEventSystemClientCopyServices with a typed ref;
        // force-cast is safe because our CFTypeRef was produced by the
        // matching Create call.
        box.services = IOHIDEventSystemClientCopyServices(client as! IOHIDEventSystemClient)
    }

    static func readAllSensors() -> [SensorReading] {
        guard box.client != nil, let services = box.services else { return [] }

        var readings: [SensorReading] = []
        let count = CFArrayGetCount(services)

        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(services, i) else { continue }
            let service: AnyObject = unsafeBitCast(rawPtr, to: AnyObject.self)
            // In SDK 15+ the public typed ref is IOHIDServiceClient; the
            // `as!` is safe because the array came from IOHIDEventSystemClient.
            let typedService = service as! IOHIDServiceClient

            guard let nameRef = IOHIDServiceClientCopyProperty(typedService, "Product" as CFString),
                  let name = nameRef as? String else { continue }

            guard let event = IOHIDServiceClientCopyEvent(service, kTempEventType, 0, 0) else { continue }
            let tempC = IOHIDEventGetFloatValue(event, kTempField)

            guard tempC > 0 else { continue }

            let registryID = AirAssist_IOHIDServiceClientGetRegistryID(service)
            let id = String(format: "%016llx", registryID)
            readings.append(SensorReading(id: id, name: name, value: tempC))
        }

        return readings.sorted { $0.name < $1.name }
    }
}
