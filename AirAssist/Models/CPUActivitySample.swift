import Foundation

/// One sample taken by `CPUActivityLog` at a sampling tick. We persist
/// these to NDJSON so the dashboard can answer "which apps were
/// actually heavy this week" — a richer signal than the throttle log
/// alone, since not every CPU hog gets throttled.
///
/// We deliberately store *per-process* samples rather than aggregated
/// counts so the aggregator can reslice the data later (e.g. "today
/// only", "in the last hour", different thresholds) without us
/// rewriting the log. Disk cost is bounded by the sampling cadence
/// (60s by default) and the number of qualifying processes per tick
/// (top 5 by CPU above the visibility floor).
struct CPUActivitySample: Codable, Hashable {
    let timestamp: Date

    /// Reverse-DNS bundle ID when resolvable (e.g. `com.apple.Safari`).
    /// Falls back to the executable name when the process doesn't
    /// have a bundle (most CLIs, daemons).
    let bundleID: String?

    /// Executable name. Used for grouping when `bundleID` is nil and
    /// for the human-readable label in the rollup.
    let name: String

    /// User-friendly display name (e.g. "Google Chrome" rather than
    /// "Google Chrome Helper (Renderer)"). Falls back to `name` when
    /// the executable is the binary itself.
    let displayName: String

    /// Running CPU percent at the sample tick. 100% = one full core
    /// — same convention as `top` and `RunningProcess.cpuPercent`.
    let cpuPercent: Double

    /// Stable group key used by the aggregator: prefer bundle ID,
    /// fall back to executable name. Keeps process renames /
    /// helper-process variants from fragmenting their app's total.
    var groupKey: String {
        if let id = bundleID, !id.isEmpty { return id }
        return name
    }
}
