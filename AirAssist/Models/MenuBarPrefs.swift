import Foundation

// MARK: - Slot model (two-level: category + value stored separately in UserDefaults)
//
// category key → "none" | "highest" | "average" | "individual"
// value key    → "overall" | "all" | SensorCategory.rawValue | sensor.id

enum SlotCategory: String, CaseIterable {
    case none       = "none"
    case highest    = "highest"
    case average    = "average"
    case individual = "individual"

    var label: String {
        switch self {
        case .none:       return "None"
        case .highest:    return "Highest"
        case .average:    return "Average"
        case .individual: return "Individual"
        }
    }

    // Default sub-value when category is first selected
    var defaultValue: String {
        switch self {
        case .none:       return ""
        case .highest:    return SensorCategory.cpu.rawValue
        case .average:    return SensorCategory.cpu.rawValue
        case .individual: return ""
        }
    }
}

// MARK: - Layout

enum MenuBarLayout: String, CaseIterable {
    case single     = "single"
    case sideBySide = "sideBySide"
    case stacked    = "stacked"

    var label: String {
        switch self {
        case .single:     return "Single"
        case .sideBySide: return "Side by Side"
        case .stacked:    return "Stacked"
        }
    }
}
