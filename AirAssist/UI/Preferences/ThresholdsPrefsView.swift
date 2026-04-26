import SwiftUI

struct ThresholdsPrefsView: View {
    let store: ThermalStore

    var body: some View {
        Form {
            Section {
                thresholdRow("CPU",     warm: \.cpu.warm,     hot: \.cpu.hot)
                thresholdRow("GPU",     warm: \.gpu.warm,     hot: \.gpu.hot)
                thresholdRow("SoC",     warm: \.soc.warm,     hot: \.soc.hot)
                thresholdRow("Battery", warm: \.battery.warm, hot: \.battery.hot)
                thresholdRow("Storage", warm: \.storage.warm, hot: \.storage.hot)
                thresholdRow("Other",   warm: \.other.warm,   hot: \.other.hot)
            } header: {
                HStack {
                    HStack(spacing: 4) {
                        Text("Category")
                        InfoButton(text: "These thresholds drive ONLY the color bands in the menu bar, popover, and dashboard — they don't trigger throttling. The governor's temperature ceiling lives in Throttling preferences. Each category gets its own pair because normal operating temperatures differ wildly (a 70°C battery is alarming; a 70°C CPU is mid-build).")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Warm (°C)").frame(width: 90)
                    Text("Hot (°C)").frame(width: 90)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func thresholdRow(
        _ label: String,
        warm warmPath: WritableKeyPath<ThresholdSettings, Double>,
        hot  hotPath:  WritableKeyPath<ThresholdSettings, Double>
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 12) {
                thresholdField(path: warmPath, tint: .orange)
                thresholdField(path: hotPath,  tint: .red)
            }
        }
    }

    private func thresholdField(
        path: WritableKeyPath<ThresholdSettings, Double>,
        tint: Color
    ) -> some View {
        let binding = Binding<Double>(
            get: { store.thresholds[keyPath: path] },
            set: {
                store.thresholds[keyPath: path] = $0
                ThresholdPersistence.save(store.thresholds)
            }
        )
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 7, height: 7)
            TextField("", value: binding, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .textFieldStyle(.squareBorder)
        }
    }
}
