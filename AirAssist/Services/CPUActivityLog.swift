import Foundation
import os

/// Persistent NDJSON log of per-process CPU samples. Counterpart to
/// `ThrottleEventLog` but for the live "what was actually running
/// hard" question — driven by a 60-second sampling cadence rather
/// than throttle apply/release events.
///
/// File path:
///     ~/Library/Application Support/AirAssist/cpu-activity.ndjson
///
/// One JSON object per line (`CPUActivitySample`). Same write
/// pattern as `ThrottleEventLog`:
///   - append-only with error logging,
///   - each distinct error class logged once to keep the unified
///     log tidy on a permanently-full disk,
///   - `pruneOldEntries` keeps the file bounded.
///
/// Default retention is 7 days — that's the window the dashboard
/// panel cares about, and 60s sampling × 5 processes/tick × 7 days
/// is roughly 50K lines / ~7 MB on disk worst case, kind to anyone
/// running the app continuously.
@MainActor
final class CPUActivityLog {
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "CPUActivityLog")

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
                Logger(subsystem: "com.sjschillinger.airassist", category: "CPUActivityLog")
                    .error("createDirectory failed for \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            self.fileURL = dir.appendingPathComponent("cpu-activity.ndjson")
        }
    }

    /// Append one sample. Caller is responsible for filtering out
    /// processes below the visibility threshold — we faithfully
    /// record whatever we're given. If you want to skip idle
    /// background helpers, do it before calling.
    func record(_ sample: CPUActivitySample) {
        var line: Data
        do {
            line = try encoder.encode(sample)
        } catch {
            recordError(error, op: "encode sample")
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

    /// Convenience: record several at once. Atomic at the
    /// per-sample level — one bad encode doesn't sink the whole
    /// batch, but a write failure mid-batch leaves the file in
    /// whatever state the OS got to. Acceptable for this kind of
    /// telemetry.
    func recordBatch(_ samples: [CPUActivitySample]) {
        for sample in samples {
            record(sample)
        }
    }

    /// Read every sample currently on disk, decoding tolerantly.
    /// Lines that fail to parse are dropped with a debug-log
    /// breadcrumb — one corrupt line shouldn't blank out the panel.
    func readAll() -> [CPUActivitySample] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return [] }
        var out: [CPUActivitySample] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty else { continue }
            do {
                let sample = try decoder.decode(CPUActivitySample.self, from: line)
                out.append(sample)
            } catch {
                logger.debug("dropping corrupt sample line: \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }

    /// Remove samples older than `keepDays` by rewriting the file.
    /// Cheap because the on-disk volume is small relative to disk
    /// IO cost — even a heavy week is a few thousand lines.
    func pruneOldEntries(keepDays: Int = 7) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return }
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        var keptLines: [Data] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty else { continue }
            if let sample = try? decoder.decode(CPUActivitySample.self, from: line),
               sample.timestamp >= cutoff {
                keptLines.append(Data(line))
            }
            // Else: corrupt or out-of-window, drop on prune.
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
            logger.error("CPUActivityLog \(op, privacy: .public) failed: \(desc, privacy: .public)")
        }
    }
}
