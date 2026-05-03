import Foundation

/// Rolling sample buffers feeding the menu bar's history-aware
/// surfaces — the popover sparkline (hottest sensor over the last
/// minute) and the CPU% slot's trend arrow.
///
/// One buffer per concept, sized at the same capacity (60 samples =
/// ~1 minute at the 1 Hz control loop). Consolidating them here
/// instead of as scattered arrays on `ThermalStore` makes adding
/// future histories (memory pressure, battery %, fan RPM as they
/// land) a 5-line change instead of pasting the append/trim pattern
/// each time.
///
/// Extracted from `ThermalStore` in v0.14.x post-release cleanup —
/// the third of three carve-ups, alongside `ManualThrottleCoordinator`
/// and `MenuBarSlotResolver`.
///
/// Lifecycle:
///   - Created in `ThermalStore.init`, ticked from the 1 Hz control
///     loop (alongside the governor / rule engine ticks).
///   - No `start()` / `stop()` — buffers are cheap, retained for the
///     life of the store, and reset implicitly via `removeAll()` if
///     anyone needs to wipe them.
///   - `@Observable` so SwiftUI views reading the buffers
///     (currently `MenuBarPopoverView.sparklineSamples`) re-render
///     on each tick.
@MainActor
@Observable
final class MenuBarHistoryBuffers {
    /// Buffer length in samples. At the 1 Hz tick this is ~1 minute
    /// of history — long enough for the trend arrow's slope estimate
    /// and short enough that the sparkline tells you about *now*,
    /// not "earlier today."
    static let capacity: Int = 60

    /// Hottest enabled sensor over time. Drives the popover
    /// sparkline. May lag if every sensor's `currentValue` is nil
    /// (e.g. boot or all-disabled state) — `appendSparkline(_:)`
    /// silently no-ops on nil rather than recording a bogus zero.
    private(set) var sparkline: [Double] = []

    /// Total system CPU% over time. Drives the trend arrow on the
    /// `cpuTotal` slot.
    private(set) var cpuTotal: [Double] = []

    /// Append a sparkline sample. Pass nil to skip — typical when no
    /// sensor has reported yet on a fresh launch.
    func appendSparkline(_ value: Double?) {
        guard let value else { return }
        sparkline.append(value)
        trim(&sparkline)
    }

    /// Append a CPU% sample. Always recorded — `0` is a meaningful
    /// "Mac was idle this tick" rather than a missing reading.
    func appendCPUTotal(_ value: Double) {
        cpuTotal.append(value)
        trim(&cpuTotal)
    }

    /// Drop oldest samples until under capacity. `removeFirst(n)` is
    /// O(n) but n is at most a handful per tick under normal flow.
    private func trim(_ buffer: inout [Double]) {
        if buffer.count > Self.capacity {
            buffer.removeFirst(buffer.count - Self.capacity)
        }
    }
}
