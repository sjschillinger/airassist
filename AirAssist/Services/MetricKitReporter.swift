import Foundation
import MetricKit
import os

/// MetricKit subscriber that persists every diagnostic payload macOS
/// delivers — crashes, hangs, CPU exceptions, disk writes — to disk so
/// they can be inspected later or bundled into a diagnostic export.
///
/// **Why this exists, given we already scrape `~/Library/Logs/DiagnosticReports`:**
///   - MetricKit delivers hang diagnostics (`MXHangDiagnostic`) that the
///     crash-reporter directory never contains. For a SIGSTOP-heavy app
///     where the worst failure mode is "main actor hung and pids stayed
///     frozen", hang telemetry is the signal we most need.
///   - MetricKit reports are structured JSON (`jsonRepresentation()`)
///     rather than Apple's `.ips` blob format, which means we can parse
///     them, trend them, and include them in DiagnosticBundle with no
///     extra tooling on the receiving end.
///   - Delivery is asynchronous and deferred — macOS hands us a batch on
///     the *next* launch after the diagnostic was captured. That matches
///     exactly the case we care about (crash, user reopens, we now have
///     the crashlog in-hand ready to ship with the next bug report).
///
/// **Where payloads land:**
///   `~/Library/Application Support/AirAssist/metrickit/`
///     - `diagnostic-<ISO8601>.json` — one file per `MXDiagnosticPayload`.
///     - `metric-<ISO8601>.json`     — one file per `MXMetricPayload`
///       (battery, CPU, memory footprints — lower priority, but cheap to keep).
///
/// The directory is pruned to the last 30 payloads on every subscribe,
/// so a crashy build can't fill the disk.
///
/// **Privacy:** Payloads are written locally, never transmitted. The only
/// way they leave the Mac is via the user-initiated `DiagnosticBundle`
/// export, which the user chooses a destination for.
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitReporter()

    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "MetricKit")
    private let fm = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.sjschillinger.airassist.metrickit",
                                        qos: .utility)

    /// Subscribe to MetricKit. Safe to call repeatedly — MXMetricManager
    /// dedups subscribers by identity. Call once from `applicationDidFinishLaunching`.
    func start() {
        MXMetricManager.shared.add(self)
        logger.debug("subscribed to MXMetricManager")
        // Prune old payloads on startup so a crashy build doesn't accumulate
        // indefinitely. We keep the last 30 of each type — ~a week of daily
        // deliveries is plenty for post-mortem and well under any practical
        // storage concern.
        ioQueue.async { [weak self] in
            self?.pruneDirectory(keepLast: 30)
        }
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    /// The directory payloads are written to. Public so `DiagnosticBundle`
    /// can copy its contents into the zip.
    static var storageDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AirAssist", isDirectory: true)
            .appendingPathComponent("metrickit", isDirectory: true)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Serialize on the delivery thread — `MXMetricPayload` is not
        // Sendable, but the `Data` we extract from it is. That lets us
        // hop to our I/O queue without @preconcurrency hacks.
        let blobs: [Data] = payloads.map { $0.jsonRepresentation() }
        ioQueue.async { [weak self] in
            guard let self else { return }
            for blob in blobs { self.write(blob, prefix: "metric") }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Extract both the JSON blob (for persistence) and a summary
        // count tuple (for logging) on this thread, then hand off.
        struct Summary { let data: Data; let crashes: Int; let hangs: Int; let cpus: Int }
        let summaries: [Summary] = payloads.map { p in
            Summary(
                data: p.jsonRepresentation(),
                crashes: p.crashDiagnostics?.count ?? 0,
                hangs: p.hangDiagnostics?.count ?? 0,
                cpus: p.cpuExceptionDiagnostics?.count ?? 0
            )
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            for s in summaries {
                self.write(s.data, prefix: "diagnostic")
                self.logger.info("MetricKit diagnostic: \(s.crashes) crash(es), \(s.hangs) hang(s), \(s.cpus) CPU exception(s)")
            }
        }
    }

    // MARK: - I/O

    private func write(_ data: Data, prefix: String) {
        let dir = Self.storageDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("create metrickit dir failed: \(String(describing: error), privacy: .public)")
            return
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // ISO8601 with `:` in the filename is legal on APFS but some tools
        // (zip, rsync, Windows hosts) trip on it. Swap colons for dashes.
        let stamp = fmt.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(prefix)-\(stamp).json")

        do {
            try data.write(to: url, options: [.atomic])
            logger.debug("wrote \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("write metrickit payload failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func pruneDirectory(keepLast n: Int) {
        let dir = Self.storageDirectory
        guard fm.fileExists(atPath: dir.path) else { return }
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Split by prefix so "diagnostic" and "metric" each keep their own
        // quota — we don't want a noisy metric stream to evict the
        // diagnostic file we actually care about.
        let byPrefix = Dictionary(grouping: contents) { url -> String in
            url.lastPathComponent.split(separator: "-").first.map(String.init) ?? "other"
        }

        for (_, files) in byPrefix {
            let sorted = files.sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ad > bd
            }
            guard sorted.count > n else { continue }
            for url in sorted.dropFirst(n) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
