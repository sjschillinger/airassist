import Foundation

enum TempUnit: Int {
    case celsius    = 0
    case fahrenheit = 1

    func format(_ celsius: Double) -> String {
        switch self {
        case .celsius:    return String(format: "%.0f°C", celsius)
        case .fahrenheit: return String(format: "%.0f°F", celsius * 9 / 5 + 32)
        }
    }
}
