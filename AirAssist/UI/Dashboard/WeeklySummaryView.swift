import SwiftUI

/// "This week" panel — answers the question Air Assist's whole pitch
/// implies: *what did this thing actually do for me?*
///
/// Lives at the bottom of the dashboard between the "Throttling now"
/// strip (live state) and "Recent activity" (last ~80 events,
/// in-memory). Reads from `ThermalStore.throttleEventLog` (the
/// persistent NDJSON), aggregated through `ThrottleSummary.aggregate`
/// over a 7-day rolling window ending now. Window is rolling rather
/// than calendar-week so the panel is meaningful immediately on a
/// Tuesday rather than waiting for next Monday to fill in.
///
/// The aggregation is recomputed on each render — cheap because the
/// log is small (a few hundred events even on a heavy throttling
/// week) and avoids a stale-cache bug class.
struct WeeklySummaryView: View {
    @Bindable var store: ThermalStore

    /// Rolling 7-day window ending now. Recomputed every render so
    /// the panel never goes stale; if this becomes a perf concern,
    /// memoize on a 1-minute timer.
    private var summary: ThrottleSummary {
        let end = Date()
        let start = end.addingTimeInterval(-7 * 86400)
        return ThrottleSummary.aggregate(store.throttleEventLog.readAll(),
                                         windowStart: start,
                                         windowEnd:   end)
    }

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text("This week").font(.headline)
                Spacer()
                Text("Last 7 days")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if s.totalEpisodes == 0 {
                // Empty state mirrors the rest of the app: never a raw
                // "nothing here", always a sentence that explains why.
                Text("No throttling activity yet — the governor and your rules haven't needed to step in.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    summaryStats(s)
                    Divider()
                    topApps(s)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: - Stats column

    @ViewBuilder
    private func summaryStats(_ s: ThrottleSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill").foregroundStyle(.orange)
                Text("\(s.totalEpisodes) episode\(s.totalEpisodes == 1 ? "" : "s")")
                    .font(.subheadline).bold().monospacedDigit()
            }
            Text(formatDuration(s.totalThrottleSeconds) + " total throttled")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(sourceOrder, id: \.self) { src in
                    let secs = s.bySource[src] ?? 0
                    if secs > 0 {
                        Label(sourceLabel(src),
                              systemImage: sourceIcon(src))
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(sourceTint(src))
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(minWidth: 200, alignment: .leading)
    }

    // Stable display order for source breakdown; matches the legend
    // colors used in the recent-activity panel.
    private var sourceOrder: [ThrottleEvent.Source] {
        [.governor, .rule, .manual, .other]
    }

    // MARK: - Top apps column

    @ViewBuilder
    private func topApps(_ s: ThrottleSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top apps").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(s.byApp.prefix(5).enumerated()), id: \.offset) { _, app in
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(formatDuration(app.seconds))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if s.byApp.count > 5 {
                Text("+\(s.byApp.count - 5) more")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

    /// Human-friendly duration. Throttle episodes range from a few
    /// seconds (governor smoothing past a brief spike) to hours of a
    /// rule capping a runaway helper, so the formatter has to span
    /// both. Keep the unit step explicit rather than relying on
    /// `DateComponentsFormatter`, which happily emits "0m 1s" or
    /// "1h 0m" depending on locale and looks busy in a one-line row.
    private func formatDuration(_ secs: TimeInterval) -> String {
        if secs < 60 { return "\(Int(secs.rounded()))s" }
        if secs < 3600 {
            let m = Int(secs / 60)
            let s = Int(secs) % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = Int(secs / 3600)
        let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private func sourceLabel(_ s: ThrottleEvent.Source) -> String {
        switch s {
        case .governor: return "Governor"
        case .rule:     return "Rule"
        case .manual:   return "Manual"
        case .other:    return "Other"
        }
    }
    private func sourceIcon(_ s: ThrottleEvent.Source) -> String {
        switch s {
        case .governor: return "gauge.with.dots.needle.67percent"
        case .rule:     return "list.bullet.rectangle"
        case .manual:   return "hand.tap"
        case .other:    return "questionmark.circle"
        }
    }
    private func sourceTint(_ s: ThrottleEvent.Source) -> Color {
        switch s {
        case .governor: return .red
        case .rule:     return .orange
        case .manual:   return .purple
        case .other:    return .secondary
        }
    }
}
