import Foundation

/// Plain Codable snapshot of per-category peak temperatures at a moment in time.
/// Stored as NDJSON lines in Application Support — no SwiftData / XPC overhead.
struct ThermalEntry: Codable {
    var timestamp: Date
    var cpuMax: Double?
    var gpuMax: Double?
    var socMax: Double?
    var batteryMax: Double?
    var storageMax: Double?
    var otherMax: Double?
}
