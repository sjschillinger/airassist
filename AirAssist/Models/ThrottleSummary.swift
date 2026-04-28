import Foundation

/// One persisted throttle event. The on-disk shape lives in
/// `throttle-events.ndjson` — see `ThrottleEventLog`. Decoded out of the
/// log by `ThrottleSummary.aggregate` to build the dashboard's
/// "This week" panel.
///
/// Source is stored as a String so the schema survives if a future
/// `ThrottleSource` case is added; unknown values fall through to
/// `.other` rather than failing the whole decode.
struct ThrottleEvent: Codable, Hashable {
    enum Kind: String, Codable { case apply, release }

    /// Stored as a string instead of the runtime `ThrottleSource` enum
    /// so adding a new source case doesn't invalidate every old log line.
    enum Source: String, Codable {
        case governor, rule, manual, other

        init(_ runtime: ThrottleSource) {
            switch runtime {
            case .governor: self = .governor
            case .rule:     self = .rule
            case .manual:   self = .manual
            }
        }

        /// Tolerant decode: an unknown raw value lands on `.other` rather
        /// than failing. Future-proofs the log against new source kinds.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .other
        }
    }

    let timestamp: Date
    let kind: Kind
    let source: Source
    let pid: Int32
    let name: String
    let duty: Double

    enum CodingKeys: String, CodingKey {
        // Compact NDJSON keys — every byte counts when this file grows
        // for months. Decoder maps back to readable property names.
        case timestamp = "ts"
        case kind, source, pid, name, duty
    }
}

/// Aggregated rollup of a window of `ThrottleEvent`s. The shape the
/// "This week" dashboard panel actually renders. Keeping it as a plain
/// value type with no observation makes it cheap to recompute when the
/// log is reread.
struct ThrottleSummary: Equatable {
    /// Half-open window [start, end). Caller decides what "this week"
    /// means; the aggregator just trusts the bounds.
    let windowStart: Date
    let windowEnd: Date

    /// Total apply events within the window. An "episode" is one
    /// transition from running → throttled for a given (name, source).
    let totalEpisodes: Int

    /// Sum across all paired apply→release intervals, clamped to the
    /// window. Open episodes (apply with no release before `windowEnd`)
    /// are counted up to `windowEnd`.
    let totalThrottleSeconds: TimeInterval

    /// Per-app breakdown sorted by `seconds` descending. Display layer
    /// typically takes the top N. Apps with zero seconds are dropped.
    let byApp: [AppRollup]

    /// Per-source seconds breakdown. Keys present even when zero so the
    /// view doesn't have to handle missing entries differently.
    let bySource: [ThrottleEvent.Source: TimeInterval]

    struct AppRollup: Equatable {
        let name: String
        let episodes: Int
        let seconds: TimeInterval
    }

    static let empty = ThrottleSummary(
        windowStart: .distantPast,
        windowEnd:   .distantPast,
        totalEpisodes: 0,
        totalThrottleSeconds: 0,
        byApp: [],
        bySource: [.governor: 0, .rule: 0, .manual: 0, .other: 0]
    )

    /// Walk a chronologically-ordered list of events and roll them up.
    ///
    /// Pairing rule: events are keyed by `(name, source)`. An `.apply`
    /// opens an episode for that key; a `.release` closes it. If a
    /// second `.apply` arrives while a key is already open, it is
    /// treated as a continuation (the existing episode keeps its start
    /// time, no extra episode is counted) — this models the cycler's
    /// re-issue behaviour without exploding the count.
    ///
    /// Events outside `[windowStart, windowEnd)` are ignored except
    /// when they help close an episode that started inside the window
    /// (a release just past `windowEnd` is clamped to `windowEnd`).
    static func aggregate(_ events: [ThrottleEvent],
                          windowStart: Date,
                          windowEnd: Date) -> ThrottleSummary {

        struct Open {
            let start: Date
            let name:  String
        }

        // (name, source) → currently-open episode start
        var open: [Key: Open] = [:]
        var perApp:    [String: (episodes: Int, seconds: TimeInterval)] = [:]
        var perSource: [ThrottleEvent.Source: TimeInterval] = [
            .governor: 0, .rule: 0, .manual: 0, .other: 0,
        ]
        var totalEpisodes = 0
        var totalSeconds: TimeInterval = 0

        // Stable processing requires chronological order. Defensive sort
        // — the on-disk log is append-only so events arrive sorted, but
        // we don't want a corrupted line midway through to silently
        // skew aggregates.
        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        for ev in sorted {
            let key = Key(name: ev.name, source: ev.source)

            switch ev.kind {
            case .apply:
                guard ev.timestamp < windowEnd else { continue }
                if open[key] == nil {
                    // Clamp episode start to windowStart so a long-running
                    // throttle that began before the window only counts
                    // its in-window portion.
                    let clampedStart = max(ev.timestamp, windowStart)
                    open[key] = Open(start: clampedStart, name: ev.name)
                    if ev.timestamp >= windowStart {
                        totalEpisodes += 1
                    }
                }

            case .release:
                guard let entry = open.removeValue(forKey: key) else { continue }
                let end = min(ev.timestamp, windowEnd)
                guard end > entry.start else { continue }
                let dur = end.timeIntervalSince(entry.start)
                totalSeconds += dur
                perSource[ev.source, default: 0] += dur
                var bucket = perApp[entry.name] ?? (0, 0)
                bucket.episodes += 1
                bucket.seconds  += dur
                perApp[entry.name] = bucket
            }
        }

        // Close any episodes still open at windowEnd.
        for (key, entry) in open {
            let end = windowEnd
            guard end > entry.start else { continue }
            let dur = end.timeIntervalSince(entry.start)
            totalSeconds += dur
            perSource[key.source, default: 0] += dur
            var bucket = perApp[entry.name] ?? (0, 0)
            bucket.episodes += 1
            bucket.seconds  += dur
            perApp[entry.name] = bucket
        }

        let apps = perApp
            .map { AppRollup(name: $0.key, episodes: $0.value.episodes, seconds: $0.value.seconds) }
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }

        return ThrottleSummary(
            windowStart: windowStart,
            windowEnd:   windowEnd,
            totalEpisodes: totalEpisodes,
            totalThrottleSeconds: totalSeconds,
            byApp: apps,
            bySource: perSource
        )
    }

    private struct Key: Hashable {
        let name:   String
        let source: ThrottleEvent.Source
    }
}
