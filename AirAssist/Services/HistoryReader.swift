import Foundation

/// Reads the NDJSON file written by `HistoryLogger`. Kept separate so UI
/// code doesn't reach into the logger's internals.
enum HistoryReader {
    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support
            .appendingPathComponent("AirAssist", isDirectory: true)
            .appendingPathComponent("thermal_history.ndjson")
    }

    /// Load all entries from disk. Returns [] if the file doesn't exist.
    /// Entries are filtered to those within `sinceHours` of now (nil = all).
    static func load(sinceHours: Double? = nil) -> [ThermalEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entries = data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(ThermalEntry.self, from: Data($0)) }

        guard let hours = sinceHours else { return entries }
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return entries.filter { $0.timestamp >= cutoff }
    }
}
