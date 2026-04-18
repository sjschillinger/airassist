import Foundation

enum SensorCategorizer {

    static func category(for rawName: String) -> SensorCategory {
        let n = rawName.lowercased()
        if n.contains("gas gauge") || n.contains("battery")          { return .battery }
        if n.contains("nand") || n.contains("ssd")                   { return .storage }
        if n.hasPrefix("pmu tdie")                                    { return .cpu }
        if n.hasPrefix("pmu2 tdie")                                   { return .gpu }
        if n.hasPrefix("pmu")                                         { return .soc }
        return .other
    }

    static func displayName(for rawName: String) -> String {
        // PMU tdie1 → CPU Die 1,  PMU2 tdie1 → GPU Die 1
        if let num = trailingInt(rawName, prefix: "PMU tdie")   { return "CPU Die \(num)" }
        if let num = trailingInt(rawName, prefix: "PMU2 tdie")  { return "GPU Die \(num)" }
        if let num = trailingInt(rawName, prefix: "PMU tdev")   { return "PMU Dev \(num)" }
        if let num = trailingInt(rawName, prefix: "PMU2 tdev")  { return "PMU2 Dev \(num)" }
        if rawName == "PMU tcal"                                { return "PMU Calibration" }
        if rawName == "PMU2 tcal"                               { return "PMU2 Calibration" }
        if rawName.lowercased().contains("gas gauge")           { return "Battery" }
        if rawName.lowercased().contains("nand")                { return "NAND Storage" }
        return rawName
    }

    private static func trailingInt(_ s: String, prefix: String) -> Int? {
        guard s.hasPrefix(prefix) else { return nil }
        return Int(s.dropFirst(prefix.count))
    }
}
