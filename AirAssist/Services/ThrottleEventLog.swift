import Foundation
import os

/// Persistent NDJSON log of throttle apply/release events. The
/// counterpart to the in-memory `ThrottleActivityLog`: that one feeds
/// the live "Recent activity" panel (capped at 80 events, no disk),
/// this one survives launches and feeds the weekly summary panel
/// (`ThrottleSummary.aggregate` on the decoded contents).
///
/// File path:
///     ~/Library/Application Support/AirAssist/throttle-events.ndjson
///
/// One JSON object per line. The schema lives in `ThrottleEvent`. We
/// follow the same pragmatic write strategy as `HistoryLogger`:
///   - append-only with `try?`-equivalent error logging,
///   - each distinct error class is logged once so a permanently-full
///     disk doesn't drown the unified log,
///   - `pruneOldEntries` keeps the file from growing unbounded.
///
/// Ninety-day retention by default. Weekly summaries only need seven
/// days, but the longer window leaves room for a future "monthly"
/// view without re-instrumenting.
@MainActor
final class ThrottleEventLog {
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "ThrottleEventLog")

    private var loggedErrorDescriptions: Set<String> = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            let dir = support.appendingPathComponent("AirAssist", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir,
                                                        withIntermediateDirectories: true)
            } catch {
                Logger(subsystem: "com.sjschillinger.airassist", category: "ThrottleEventLog")
                    .error("createDirectory failed for \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            self.fileURL = dir.appendingPathComponent("throttle-events.ndjson")
        }
    }

    /// Append one apply/release event. Coalescing is *not* applied here
    /// — the persistent log keeps the full event stream so summaries
    /// can pair apply→release accurately. If you want coalesced
    /// display events, read `ThrottleActivityLog`.
    func record(kind: ThrottleEvent.Kind,
                source: ThrottleSource,
                pid: pid_t,
                name: String,
                duty: Double) {
        let event = ThrottleEvent(
            timestamp: Date(),
            kind: kind,
            source: ThrottleEvent.Source(source),
            pid: pid,
            name: name,
            duty: duty
        )
        var line: Data
        do {
            line = try encoder.encode(event)
        } catch {
            recordError(error, op: "encode event")
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

    /// Read every event currently on disk, decoding tolerantly. Lines
    /// that fail to parse are dropped with a debug-log breadcrumb —
    /// one corrupt line shouldn't blank out the whole summary.
    func readAll() -> [ThrottleEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return [] }
        var out: [ThrottleEvent] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty else { continue }
            do {
                let ev = try decoder.decode(ThrottleEvent.self, from: line)
                out.append(ev)
            } catch {
                logger.debug("dropping corrupt event line: \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }

    /// Remove entries older than `keepDays` by rewriting the file.
    /// Cheap because the on-disk volume is small — a heavy throttling
    /// session generates a few hundred lines a day, not thousands.
    func pruneOldEntries(keepDays: Int = 90) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return }
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        var keptLines: [Data] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty else { continue }
            if let ev = try? decoder.decode(ThrottleEvent.self, from: line),
               ev.timestamp >= cutoff {
                keptLines.append(Data(line))
            } else if (try? decoder.decode(ThrottleEvent.self, from: line)) == nil {
                // Drop unparseable lines as part of the prune — same as readAll
                // skipping them. Don't keep corrupt lines around forever.
            }
        }
        var rewritten = Data()
        for var l in keptLines {
            l.append(UInt8(ascii: "\n"))
            rewritten.append(l)
        }
        do {
            try rewritten.write(to: fileURL, options: .atomic)
        } catch {
            recordError(error, op: "rewrite during prune")
        }
    }

    private func recordError(_ error: Error, op: String) {
        let desc = String(describing: error)
        if loggedErrorDescriptions.insert(desc).inserted {
            logger.error("ThrottleEventLog \(op, privacy: .public) failed: \(desc, privacy: .public)")
        }
    }
}
