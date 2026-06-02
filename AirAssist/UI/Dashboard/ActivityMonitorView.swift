import SwiftUI
import AppKit

/// Activity-Monitor-style live process list. The interactive counterpart
/// to the read-only `CPUConsumersView` (7-day rollup) and the popover's
/// compact "CPU Activity" section: a full, sortable table of what's
/// running right now with per-process controls.
///
/// Data source: `store.snapshots.latest` — the same 1 Hz snapshot the
/// governor and rule engine already consume (top ~50 user-visible
/// processes by CPU, system-hidden names filtered out). This view adds
/// no sampling of its own; it only re-reads that buffer on a 2 s tick
/// while it is on screen, so it can never reintroduce a background
/// render cost when the window or tab is hidden.
///
/// Per-row actions reuse the existing throttle backends:
///   - Limit to X%  → `store.throttleFrontmost` (manual duty-cycle cap)
///   - Pause        → manual cap at the throttler's minimum duty
///   - Release      → `store.releaseManualThrottle`
///   - Reveal       → Finder
///   - Never throttle → `NeverThrottleList`
/// Protected processes (Xcode, terminals, agents) show a badge instead
/// of throttle actions — same policy as every other visibility surface.
struct ActivityMonitorView: View {
    @Bindable var store: ThermalStore

    /// Refresh tick. Bumped every 2 s while visible so the table re-reads
    /// the latest snapshot. Gated by `isVisible` so a hidden tab / closed
    /// window does no work.
    @State private var tick = Date()
    @State private var isVisible = false
    @State private var sortOrder = [KeyPathComparator(\ActivityRow.cpuPercent, order: .reverse)]
    @State private var search = ""

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let rows = currentRows()
        VStack(spacing: 0) {
            header(total: rows.reduce(0) { $0 + $1.cpuPercent },
                   count: rows.count)
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name) { row in
                    processCell(row)
                }
                .width(min: 160, ideal: 220)

                TableColumn("CPU", value: \.cpuPercent) { row in
                    Text("\(row.cpuPercent, specifier: "%.1f")%")
                        .monospacedDigit()
                        .foregroundStyle(cpuTint(row.cpuPercent))
                }
                .width(min: 60, ideal: 70)

                TableColumn("Memory", value: \.rssBytes) { row in
                    Text(formatBytes(row.rssBytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)

                TableColumn("") { row in
                    actionMenu(row)
                }
                .width(40)
            }
            .tableStyle(.inset)
        }
        .onReceive(refreshTimer) { if isVisible { tick = $0 } }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    // MARK: - Header

    private func header(total: Double, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu").foregroundStyle(.blue)
            Text("Activity").font(.headline)
            Spacer()
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Text("\(count) processes · \(Int(total))% CPU")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Cells

    @ViewBuilder
    private func processCell(_ row: ActivityRow) -> some View {
        HStack(spacing: 6) {
            Text(row.name).lineLimit(1)
            if row.isProtected {
                Text("Protected")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            } else if let duty = row.cappedDuty {
                Text("capped \(Int(duty * 100))%")
                    .font(.caption2).foregroundStyle(.purple)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.12), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func actionMenu(_ row: ActivityRow) -> some View {
        Menu {
            if row.isProtected {
                Text("Protected — never throttled")
            } else {
                Menu("Limit CPU to…") {
                    ForEach([10, 25, 50, 75], id: \.self) { pct in
                        Button("\(pct)%") { cap(row, duty: Double(pct) / 100) }
                    }
                }
                if row.cappedDuty != nil {
                    Button("Release cap") { store.releaseManualThrottle(pid: row.id) }
                } else {
                    Button("Pause (suspend)") { cap(row, duty: ProcessThrottler.minDuty) }
                }
                Divider()
                Button("Never throttle this app") {
                    NeverThrottleList.add(row.name)
                    store.releaseManualThrottle(pid: row.id)
                }
            }
            Divider()
            if row.executablePath != nil {
                Button("Reveal in Finder") { reveal(row) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Actions

    /// Cap a process via the manual throttle. Long duration so the cap
    /// reads as "until I release it" in the popover countdown rather than
    /// silently expiring; Phase B replaces this with true cross-restart
    /// persistence.
    private func cap(_ row: ActivityRow, duty: Double) {
        store.throttleFrontmost(pid: row.id, name: row.name,
                                duty: duty,
                                duration: 60 * 60 * 24 * 365)
    }

    private func reveal(_ row: ActivityRow) {
        guard let path = row.executablePath else { return }
        // Reveal the .app bundle when the executable lives inside one,
        // otherwise the binary itself.
        var url = URL(fileURLWithPath: path)
        while url.pathExtension != "app" && url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let target = url.pathExtension == "app" ? url : URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Data

    /// Build the sorted, filtered row set from the latest snapshot.
    /// `tick` is read so SwiftUI re-runs this on each refresh.
    private func currentRows() -> [ActivityRow] {
        _ = tick
        let capped = Dictionary(
            store.liveThrottledPIDs.map { ($0.pid, $0.duty) },
            uniquingKeysWith: { a, _ in a }
        )
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.snapshots.latest
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .map { p in
                ActivityRow(
                    id: p.id,
                    name: p.name,
                    cpuPercent: p.cpuPercent,
                    rssBytes: p.rssBytes,
                    executablePath: p.executablePath,
                    isProtected: ProcessInspector.isProtected(p.name),
                    cappedDuty: capped[p.id]
                )
            }
            .sorted(using: sortOrder)
    }

    // MARK: - Formatting

    private func cpuTint(_ pct: Double) -> Color {
        switch pct {
        case ..<25:  return .primary
        case ..<75:  return .orange
        default:     return .red
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb < 1024 { return "\(Int(mb)) MB" }
        return String(format: "%.1f GB", mb / 1024)
    }
}

/// Flattened, sortable view-model for one process row. Decouples the
/// table from `RunningProcess` so the sort key paths are simple and the
/// throttle state (`cappedDuty`) lives alongside the static fields.
struct ActivityRow: Identifiable {
    let id: pid_t
    let name: String
    let cpuPercent: Double
    let rssBytes: UInt64
    let executablePath: String?
    let isProtected: Bool
    /// Current applied duty if this PID is throttled, else nil.
    let cappedDuty: Double?
}
