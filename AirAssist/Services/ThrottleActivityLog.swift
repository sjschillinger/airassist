import Foundation
import Observation

/// Ring buffer of recent throttle events for the dashboard's "Recent
/// activity" panel. Memory-only by design — this is for the last few
/// dozen events the user might glance at, not for long-term history.
/// Persistent thermal sampling lives in `HistoryLogger`.
///
/// Each entry records: when, what (apply/release), source (governor /
/// rule / manual), pid, name, and the duty fraction at that moment.
/// The panel reads `entries` in newest-first order.
@MainActor
@Observable
final class ThrottleActivityLog {

    enum Kind: String { case apply, release }

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let kind: Kind
        let source: ThrottleSource
        let pid: pid_t
        let name: String
        let duty: Double
    }

    private(set) var entries: [Entry] = []
    private static let capacity = 80

    func record(kind: Kind, source: ThrottleSource, pid: pid_t, name: String, duty: Double) {
        // Coalesce: avoid logging duplicate consecutive entries with the
        // same (kind, source, pid, duty) so the cycler's per-tick reapply
        // doesn't drown the buffer.
        if let last = entries.first,
           last.kind == kind, last.source == source,
           last.pid == pid, abs(last.duty - duty) < 0.005 {
            return
        }
        entries.insert(
            Entry(timestamp: Date(),
                  kind: kind,
                  source: source,
                  pid: pid,
                  name: name,
                  duty: duty),
            at: 0
        )
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
