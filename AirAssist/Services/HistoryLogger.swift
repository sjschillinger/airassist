import Foundation

/// Appends one JSON line per log() call to a rolling NDJSON file in Application Support.
/// File-based — no XPC, no ModelContainer, no background process connections.
@MainActor
final class HistoryLogger {
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("AirAssist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("thermal_history.ndjson")
    }

    func log(store: ThermalStore) {
        let entry = ThermalEntry(
            timestamp:   Date(),
            cpuMax:      store.highestTemp(in: .cpu),
            gpuMax:      store.highestTemp(in: .gpu),
            socMax:      store.highestTemp(in: .soc),
            batteryMax:  store.highestTemp(in: .battery),
            storageMax:  store.highestTemp(in: .storage),
            otherMax:    store.highestTemp(in: .other)
        )
        guard var line = try? encoder.encode(entry) else { return }
        line.append(contentsOf: [UInt8(ascii: "\n")])

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let fh = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }

    /// Remove entries older than `keepDays` by rewriting the file without them.
    func pruneOldEntries(keepDays: Int = 30) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder2 = JSONEncoder()
        encoder2.dateEncodingStrategy = .iso8601

        let kept = data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(ThermalEntry.self, from: Data($0)) }
            .filter { $0.timestamp >= cutoff }

        let output = kept
            .compactMap { try? encoder2.encode($0) }
            .joined(separator: [UInt8(ascii: "\n")])
        var bytes = Data(output)
        if !bytes.isEmpty { bytes.append(UInt8(ascii: "\n")) }
        try? bytes.write(to: fileURL)
    }
}
