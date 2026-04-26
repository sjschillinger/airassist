import Foundation
import os

/// Appends one JSON line per log() call to a rolling NDJSON file in Application Support.
/// File-based — no XPC, no ModelContainer, no background process connections.
///
/// Writes used to be silently `try?`'d throughout — when the disk filled up
/// or the directory became read-only, history quietly stopped growing and
/// the dashboard looked frozen with no signal anywhere. Failures now log
/// once per error class so the diagnostic bundle can capture them. (audit
/// Tier 0 item 3; Codex VERIFIED.)
@MainActor
final class HistoryLogger {
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "HistoryLogger")
    /// Track which write-failure classes we've already complained about,
    /// keyed by the localized error description. Prevents log-floods when
    /// the disk is permanently full — one line per distinct cause.
    private var loggedErrorDescriptions: Set<String> = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("AirAssist", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            // Init-time logger needs the instance, so use a direct subsystem
            // logger here. Directory creation almost never fails on a well-
            // formed user — encrypted volume edge cases are the worst case.
            Logger(subsystem: "com.sjschillinger.airassist", category: "HistoryLogger")
                .error("createDirectory failed for \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
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
        var line: Data
        do {
            line = try encoder.encode(entry)
        } catch {
            recordError(error, op: "encode entry")
            return
        }
        line.append(contentsOf: [UInt8(ascii: "\n")])

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let fh = try FileHandle(forWritingTo: fileURL)
                defer { try? fh.close() }
                try fh.seekToEnd()
                try fh.write(contentsOf: line)
            } catch {
                recordError(error, op: "append to \(fileURL.lastPathComponent)")
            }
        } else {
            do {
                try line.write(to: fileURL)
            } catch {
                recordError(error, op: "create \(fileURL.lastPathComponent)")
            }
        }
    }

    /// Log distinct write-failure classes once each. Same disk-full error
    /// hammered every second would otherwise drown the unified log.
    private func recordError(_ error: Error, op: String) {
        let desc = String(describing: error)
        if loggedErrorDescriptions.insert(desc).inserted {
            logger.error("HistoryLogger \(op, privacy: .public) failed: \(desc, privacy: .public)")
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
        do {
            try bytes.write(to: fileURL)
        } catch {
            recordError(error, op: "prune-rewrite \(fileURL.lastPathComponent)")
        }
    }
}
