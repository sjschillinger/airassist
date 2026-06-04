import SwiftUI
import Charts

/// Time-series view of per-category peak temperatures over the last N hours.
/// Reads the NDJSON file written by `HistoryLogger` (one entry every 30s).
struct HistoryView: View {

    enum Range: String, CaseIterable, Identifiable {
        case last1h  = "1h"
        case last6h  = "6h"
        case last24h = "24h"
        case last7d  = "7d"
        case all     = "All"
        var id: String { rawValue }

        /// Picker label. The hour abbreviations are universal; only "All"
        /// needs translating.
        var displayName: String {
            self == .all ? String(localized: "All") : rawValue
        }

        var hours: Double? {
            switch self {
            case .last1h:  return 1
            case .last6h:  return 6
            case .last24h: return 24
            case .last7d:  return 24 * 7
            case .all:     return nil
            }
        }
    }

    @AppStorage("tempUnit") private var tempUnitRaw: Int = TempUnit.celsius.rawValue
    private var unit: TempUnit { TempUnit(rawValue: tempUnitRaw) ?? .celsius }

    @State private var range: Range = .last6h
    @State private var entries: [ThermalEntry] = []
    @State private var refreshTask: Task<Void, Never>?
    /// Timestamp of the sample currently under the cursor (snapped to the
    /// nearest logged entry). Drives the hover rule + value readout.
    @State private var hoverTime: Date?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                chart
                    .padding(16)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear {
            reload()
            refreshTask?.cancel()
            refreshTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    reload()
                }
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { r in Text(r.displayName).tag(r) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Spacer()

            Text("\(entries.count) samples")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: range) { _, _ in reload() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No history yet")
                .font(.headline)
            Text("Samples are logged every 30 seconds. Leave Air Assist running to build up a history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chart

    private struct Point: Identifiable {
        let id = UUID()
        let time: Date
        let category: String
        let value: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        for e in entries {
            if let v = e.cpuMax     { out.append(Point(time: e.timestamp, category: SensorCategory.cpu.displayName,     value: convert(v))) }
            if let v = e.gpuMax     { out.append(Point(time: e.timestamp, category: SensorCategory.gpu.displayName,     value: convert(v))) }
            if let v = e.socMax     { out.append(Point(time: e.timestamp, category: SensorCategory.soc.displayName,     value: convert(v))) }
            if let v = e.batteryMax { out.append(Point(time: e.timestamp, category: SensorCategory.battery.displayName, value: convert(v))) }
            if let v = e.storageMax { out.append(Point(time: e.timestamp, category: SensorCategory.storage.displayName, value: convert(v))) }
            if let v = e.otherMax   { out.append(Point(time: e.timestamp, category: SensorCategory.other.displayName,   value: convert(v))) }
        }
        return out
    }

    private func convert(_ celsius: Double) -> Double {
        unit == .celsius ? celsius : celsius * 9.0/5.0 + 32.0
    }

    @ViewBuilder
    private var chart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("Temp", p.value)
                )
                .foregroundStyle(by: .value("Category", p.category))
                .interpolationMethod(.monotone)
            }
            // Hover indicator: a vertical rule at the snapped sample. The
            // value readout is drawn in the overlay (below) so it can be
            // clamped inside the plot and never crops at the top edge.
            if let hoverTime, let entry = entry(nearest: hoverTime) {
                RuleMark(x: .value("Time", entry.timestamp))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYAxisLabel(unit == .celsius ? "°C" : "°F")
        .chartLegend(position: .bottom, alignment: .leading)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot else { return }
                            if let date: Date = proxy.value(atX: location.x - plot.minX) {
                                hoverTime = date
                            }
                        case .ended:
                            hoverTime = nil
                        }
                    }
                if let hoverTime, let entry = entry(nearest: hoverTime),
                   let plot, let x = proxy.position(forX: entry.timestamp) {
                    let cardW: CGFloat = 132
                    // Keep the card fully inside the plot horizontally, and
                    // pinned a little below the top edge so it never clips.
                    let cx = min(max(plot.minX + x, plot.minX + cardW / 2),
                                 plot.maxX - cardW / 2)
                    hoverReadout(entry)
                        .frame(width: cardW)
                        .position(x: cx, y: plot.minY + 62)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Floating readout card listing each category's temperature at the
    /// hovered sample.
    private func hoverReadout(_ entry: ThermalEntry) -> some View {
        let rows: [(String, Double?)] = [
            (SensorCategory.cpu.displayName, entry.cpuMax),
            (SensorCategory.gpu.displayName, entry.gpuMax),
            (SensorCategory.soc.displayName, entry.socMax),
            (SensorCategory.battery.displayName, entry.batteryMax),
            (SensorCategory.storage.displayName, entry.storageMax),
            (SensorCategory.other.displayName, entry.otherMax)
        ]
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { name, value in
                HStack(spacing: 6) {
                    Text(name).font(.caption2)
                    Spacer(minLength: 8)
                    Text("\(Int(convert(value!).rounded()))°\(unit == .celsius ? "C" : "F")")
                        .font(.caption2.monospacedDigit()).bold()
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.2)))
        .frame(width: 130)
    }

    /// Nearest logged entry to a hovered time, so the readout snaps to real
    /// data points rather than interpolating between them.
    private func entry(nearest target: Date) -> ThermalEntry? {
        entries.min {
            abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target))
        }
    }

    // MARK: - Data

    private func reload() {
        entries = HistoryReader.load(sinceHours: range.hours)
            .sorted { $0.timestamp < $1.timestamp }
    }
}
