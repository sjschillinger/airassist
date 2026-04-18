import SwiftUI

struct SensorCardView: View {
    let sensor: Sensor
    let thresholds: ThresholdSettings
    let unit: TempUnit

    private var state: ThresholdState { sensor.thresholdState(using: thresholds) }

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
            if samples.count < 2 {
                Path { path in
                    let y = h / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(tint.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
            } else {
                let minV = samples.min()!
                let maxV = samples.max()!
                // Pad range so a flat-ish line doesn't hug the top/bottom.
                let span = max(maxV - minV, 1.0)
                let lo = minV - span * 0.15
                let hi = maxV + span * 0.15
                let range = hi - lo

                let step = w / CGFloat(samples.count - 1)
                let points = samples.enumerated().map { (i, v) in
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
