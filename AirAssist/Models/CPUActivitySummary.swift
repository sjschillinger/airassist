import Foundation

/// Rollup of `CPUActivitySample` over a time window. Surfaces the
/// "habitual CPU consumers" view on the dashboard — answers the
/// question the throttle log can't: which apps were heavy *even when
/// we didn't end up throttling them*.
///
/// Pure value type. The aggregation function is a free function so
/// it's trivially unit-testable without instantiating any service.
struct CPUActivitySummary: Equatable {

    struct ConsumerRow: Identifiable, Hashable {
        var id: String { groupKey }

        /// Stable group key: bundle ID if the process had one,
        /// otherwise executable name. Matches `CPUActivitySample.groupKey`.
        let groupKey: String

        /// Best human-readable label. Picked from the most recent
        /// sample's `displayName` so app renames take effect quickly.
        let displayName: String

        /// Total wall-clock time spent above the activity threshold.
        /// Approximated as `count * sampleIntervalSeconds`, since each
        /// sample represents one tick of the sampling cadence.
        let activeSeconds: Double

        /// Mean CPU% across qualifying samples (those above the
        /// threshold). Skewed toward higher values since the threshold
        /// filters lower ones out.
        let avgCpuPercent: Double

        /// Highest CPU% observed for this group within the window.
        let peakCpuPercent: Double

        /// How many samples this group contributed. Useful for sanity
        /// checks ("did this app really run hot for 4 hours, or just
        /// briefly?") but the dashboard prefers `activeSeconds`.
        let sampleCount: Int
    }

    /// Window the summary was computed over (inclusive start,
    /// inclusive end). Echoed back in the panel header so users can
    /// tell "last 7 days" actually meant the right thing.
    let windowStart: Date
    let windowEnd: Date

    /// Threshold (in CPU%) used to decide if a sample counted as
    /// "active". Defaults to 10 — captures sustained user-visible
    /// load while skipping background heartbeats.
    let activityThreshold: Double

    /// Top-N rows sorted descending by `activeSeconds`. The aggregator
    /// always returns at most `topN` rows; if fewer groups qualify
    /// the array is shorter.
    let rows: [ConsumerRow]

    /// True if no samples landed in the window at all (vs. samples
    /// existed but none were above threshold). Lets the dashboard
    /// distinguish "Mac was idle" from "Mac wasn't watched yet".
    let isEmpty: Bool
}

/// Aggregate samples into a summary. Pure function — given the same
/// inputs, returns the same output, so tests can pin behaviour.
///
/// - Parameters:
///   - samples: every sample on disk for the relevant window
///     (caller is welcome to over-fetch and let this function
///     window-clamp).
///   - windowStart: inclusive lower bound.
///   - windowEnd: inclusive upper bound.
///   - sampleIntervalSeconds: cadence the log was written at.
///     Used to translate "sample count" into "active seconds".
///   - activityThreshold: CPU% at or above which a sample counts.
///   - topN: how many rows to return.
func cpuActivitySummary(
    samples: [CPUActivitySample],
    windowStart: Date,
    windowEnd: Date,
    sampleIntervalSeconds: Double,
    activityThreshold: Double = 10.0,
    topN: Int = 10
) -> CPUActivitySummary {
    // Window-clamp first so the activeSeconds math is honest about
    // what we actually observed. Out-of-window samples drop here.
    let inWindow = samples.filter { sample in
        sample.timestamp >= windowStart && sample.timestamp <= windowEnd
    }

    // If nothing in window at all → distinguishable empty state.
    let isEmptyWindow = inWindow.isEmpty

    // Apply the threshold AFTER window-clamping. A sample below
    // threshold counts as "we observed this process but it wasn't
    // doing much" — we drop it entirely from the rollup.
    let qualifying = inWindow.filter { $0.cpuPercent >= activityThreshold }

    // Group by stable key (bundleID || name).
    var groups: [String: [CPUActivitySample]] = [:]
    for sample in qualifying {
        groups[sample.groupKey, default: []].append(sample)
    }

    // Build a row per group. displayName is taken from the *latest*
    // sample so app renames / window-title-derived names take effect.
    let rows: [CPUActivitySummary.ConsumerRow] = groups.map { key, samples in
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let latest = sorted.last!
        let cpuValues = samples.map(\.cpuPercent)
        let total = cpuValues.reduce(0, +)
        let avg = cpuValues.isEmpty ? 0 : total / Double(cpuValues.count)
        let peak = cpuValues.max() ?? 0
        return CPUActivitySummary.ConsumerRow(
            groupKey: key,
            displayName: latest.displayName,
            activeSeconds: Double(samples.count) * sampleIntervalSeconds,
            avgCpuPercent: avg,
            peakCpuPercent: peak,
            sampleCount: samples.count
        )
    }
    .sorted { lhs, rhs in
        // Tie-break by peak CPU% so identical activeSeconds doesn't
        // produce nondeterministic ordering between runs.
        if lhs.activeSeconds != rhs.activeSeconds {
            return lhs.activeSeconds > rhs.activeSeconds
        }
        return lhs.peakCpuPercent > rhs.peakCpuPercent
    }

    return CPUActivitySummary(
        windowStart: windowStart,
        windowEnd: windowEnd,
        activityThreshold: activityThreshold,
        rows: Array(rows.prefix(topN)),
        isEmpty: isEmptyWindow
    )
}
