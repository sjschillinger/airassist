import SwiftUI

/// "Top CPU consumers — this week" panel. Sits on the dashboard as
/// the read-only counterpart to the popover's live "CPU Activity"
/// section: while the popover answers "what's running hard right
/// now", this view answers "which apps were habitually heavy in
/// the last seven days".
///
/// Reads from `ThermalStore.cpuActivityLog` (NDJSON, on disk),
/// aggregated through `cpuActivitySummary` over a 7-day rolling
/// window ending now. Window is rolling rather than calendar-week
/// so the panel is meaningful immediately on a Tuesday rather than
/// waiting for next Monday to fill in — same convention as
/// `WeeklySummaryView`.
///
/// Aggregation is recomputed on each render. Cheap because the log
/// is small (≤ a few thousand lines / week) and avoids the stale-
/// cache class of bug.
struct CPUConsumersView: View {
    @Bindable var store: ThermalStore

    /// Rolling 7-day summary. Recomputed every render — see the
    /// header comment for why we don't memoize.
    private var summary: CPUActivitySummary {
        let end = Date()
        let start = end.addingTimeInterval(-7 * 86400)
        return cpuActivitySummary(
            samples: store.cpuActivityLog.readAll(),
            windowStart: start,
            windowEnd: end,
            sampleIntervalSeconds: ThermalStore.cpuActivitySampleIntervalSeconds
        )
    }

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(.blue)
                Text("Top CPU consumers").font(.headline)
                Spacer()
                Text("Last 7 days")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if s.isEmpty {
                // First-run / no data yet. Distinguishable from
                // "Mac was idle" — the log itself was empty.
                Text("Sampling… check back after Air Assist has been running for a while.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if s.rows.isEmpty {
                // Window had samples, but nothing crossed the
                // activity threshold. Not common — implies a quiet
                // week with no sustained CPU pressure.
                Text("No app crossed the activity threshold (\(Int(s.activityThreshold))% CPU) in the last 7 days. Quiet week.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                consumerList(s)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.secondary.opacity(0.04))
    }

    @ViewBuilder
    private func consumerList(_ s: CPUActivitySummary) -> some View {
        VStack(spacing: 0) {
            ForEach(s.rows) { row in
                consumerRow(row, totalActiveSeconds: maxActiveSeconds(s))
                if row.id != s.rows.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    /// Used to size the bar visualizations relative to the
    /// heaviest-consuming app in the rollup, so the row with the
    /// most active time fills the bar and everything else scales.
    private func maxActiveSeconds(_ s: CPUActivitySummary) -> Double {
        s.rows.map(\.activeSeconds).max() ?? 1
    }

    @ViewBuilder
    private func consumerRow(_ row: CPUActivitySummary.ConsumerRow,
                             totalActiveSeconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.displayName)
                    .font(.subheadline).lineLimit(1)
                Spacer()
                Text(formatActiveDuration(row.activeSeconds))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            // Width-proportional bar — at-a-glance comparison
            // between rows. Tinted by peak CPU% so a chronic 30%
            // hog reads visually different from a brief 200% spike.
            GeometryReader { geo in
                let fraction = totalActiveSeconds > 0
                    ? row.activeSeconds / totalActiveSeconds
                    : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(peakTint(row.peakCpuPercent))
                        .frame(width: max(2, geo.size.width * fraction),
                               height: 4)
                }
            }
            .frame(height: 4)
            HStack(spacing: 8) {
                Text("avg \(Int(row.avgCpuPercent))%")
                Text("·")
                Text("peak \(Int(row.peakCpuPercent))%")
            }
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 6)
    }

    /// Format active duration the same way the throttle summary
    /// formats throttled duration — keeps the dashboard's two
    /// "this week" panels visually consistent.
    private func formatActiveDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 {
            let m = s / 60
            return "\(m)m"
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Color the bar by peak CPU% the app hit — sustained 30% and
    /// brief 200% are both interesting but for different reasons,
    /// and the color tells you which.
    private func peakTint(_ peak: Double) -> Color {
        switch peak {
        case ..<50:    return .blue
        case ..<150:   return .orange
        default:       return .red
        }
    }
}
