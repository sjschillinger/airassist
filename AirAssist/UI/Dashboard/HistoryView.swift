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
                ForEach(Range.allCases) { r in Text(r.rawValue).tag(r) }
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
            if let v = e.cpuMax     { out.append(Point(time: e.timestamp, category: "CPU",     value: convert(v))) }
            if let v = e.gpuMax     { out.append(Point(time: e.timestamp, category: "GPU",     value: convert(v))) }
            if let v = e.socMax     { out.append(Point(time: e.timestamp, category: "SoC",     value: convert(v))) }
            if let v = e.batteryMax { out.append(Point(time: e.timestamp, category: "Battery", value: convert(v))) }
            if let v = e.storageMax { out.append(Point(time: e.timestamp, category: "Storage", value: convert(v))) }
            if let v = e.otherMax   { out.append(Point(time: e.timestamp, category: "Other",   value: convert(v))) }
        }
        return out
    }

    private func convert(_ celsius: Double) -> Double {
        unit == .celsius ? celsius : celsius * 9.0/5.0 + 32.0
    }

    @ViewBuilder
    private var chart: some View {
        Chart(points) { p in
            LineMark(
                x: .value("Time", p.time),
                y: .value("Temp", p.value)
            )
            .foregroundStyle(by: .value("Category", p.category))
            .interpolationMethod(.monotone)
        }
        .chartYAxisLabel(unit == .celsius ? "°C" : "°F")
        .chartLegend(position: .bottom, alignment: .leading)
    }

    // MARK: - Data

    private func reload() {
        entries = HistoryReader.load(sinceHours: range.hours)
            .sorted { $0.timestamp < $1.timestamp }
    }
}
