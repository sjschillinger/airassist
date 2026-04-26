import SwiftUI

struct SensorCardView: View {
    let sensor: Sensor
    let thresholds: ThresholdSettings
    let unit: TempUnit

    @State private var isFavorite: Bool = false
    @State private var defaultsObserver: NSObjectProtocol?

    private var state: ThresholdState { sensor.thresholdState(using: thresholds) }

    // TODO_POST_LAUNCH (#14 contrast): system `.green` against
    // `.regularMaterial` falls below WCAG AA large-text (3:1) in light mode.
    // Replace with a palette that passes AA on both materials before v1.1.
    // Visual design was locked as-shipping for v1.0 per LAUNCH_CHECKLIST
    // #9/#10, so this is deferred rather than changed under the deadline.
    private var stateColor: Color {
        switch state {
        case .cool:    return .green
        case .warm:    return .orange
        case .hot:     return .red
        case .unknown: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                Text(sensor.category.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    SensorFavorites.toggle(sensor.id)
                    isFavorite = SensorFavorites.isFavorite(sensor.id)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Remove from favorites" : "Pin to top")
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
            }

            // Sensor name
            Text(sensor.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Spacer()

            // Temperature
            Text(sensor.currentValue.map { unit.format($0) } ?? "–")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(stateColor)

            // Real sparkline from the sensor's rolling history
            Sparkline(samples: sensor.history, tint: stateColor)
                .frame(height: 24)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(stateColor.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .onAppear {
            isFavorite = SensorFavorites.isFavorite(sensor.id)
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    let fresh = SensorFavorites.isFavorite(sensor.id)
                    if fresh != isFavorite { isFavorite = fresh }
                }
            }
        }
        .onDisappear {
            if let o = defaultsObserver {
                NotificationCenter.default.removeObserver(o)
                defaultsObserver = nil
            }
        }
    }

    /// VoiceOver label: category + sensor + threshold state, in a form a
    /// screen reader can speak without the user needing to see the colored
    /// status dot. Temperature is exposed separately as the accessibility
    /// value so VoiceOver reads "Sensor: <name>, hot — 87°C".
    private var accessibilityLabel: String {
        let stateWord: String
        switch state {
        case .cool: stateWord = "cool"
        case .warm: stateWord = "warm"
        case .hot:  stateWord = "hot"
        case .unknown: stateWord = "no reading"
        }
        return "\(sensor.category.rawValue) sensor, \(sensor.displayName), \(stateWord)"
    }

    private var accessibilityValue: String {
        guard let v = sensor.currentValue else { return "no reading" }
        return unit.format(v)
    }
}

// MARK: - Sparkline

/// Compact line chart of the last N temperature samples. Auto-scales to
/// the observed min/max with a small padding band so flat lines still
/// show as a line rather than clipping to the top or bottom edge.
private struct Sparkline: View {
    let samples: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Force-unwraps on samples.min()/max() removed — if `samples`
            // mutates between the count check and the min/max calls (or
            // contains NaN / Inf, for which min/max return nil or propagate
            // a poison value), the force unwrap crashes the Dashboard.
            // Compute min/max defensively; fall back to the dashed
            // placeholder for any degenerate input.
            let finite = samples.filter { $0.isFinite }
            let minV = finite.min()
            let maxV = finite.max()
            if finite.count < 2 || minV == nil || maxV == nil {
                Path { path in
                    let y = h / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(tint.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
            } else if let minV, let maxV {
                // Pad range so a flat-ish line doesn't hug the top/bottom.
                let span = max(maxV - minV, 1.0)
                let lo = minV - span * 0.15
                let hi = maxV + span * 0.15
                let range = hi - lo

                let step = w / CGFloat(finite.count - 1)
                let points = finite.enumerated().map { (i, v) in
                    CGPoint(
                        x: step * CGFloat(i),
                        y: h - (CGFloat((v - lo) / range) * h)
                    )
                }

                // Gradient fill under the line.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: points[0])
                    for p in points.dropFirst() { path.addLine(to: p) }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [tint.opacity(0.25), tint.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                ))

                // Line.
                Path { path in
                    path.move(to: points[0])
                    for p in points.dropFirst() { path.addLine(to: p) }
                }
                .stroke(tint.opacity(0.9), lineWidth: 1.4)
            }
        }
    }
}
