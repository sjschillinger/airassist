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

            // Placeholder sparkline
            SparklinePlaceholder()
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

// MARK: - Sparkline placeholder (replaced with real data in a later step)

private struct SparklinePlaceholder: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                let points: [CGFloat] = [0.5, 0.4, 0.55, 0.45, 0.5, 0.6, 0.5]
                let step = w / CGFloat(points.count - 1)
                path.move(to: CGPoint(x: 0, y: h * points[0]))
                for (i, y) in points.enumerated().dropFirst() {
                    path.addLine(to: CGPoint(x: step * CGFloat(i), y: h * y))
                }
            }
            .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
        }
    }
}
