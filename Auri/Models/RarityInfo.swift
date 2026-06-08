import Foundation

struct RarityInfo: Codable, Hashable {
    enum Level: String, Codable {
        case unknown
        case expected
        case unusual

        var label: String {
            switch self {
            case .unknown: return "Unknown"
            case .expected: return "Expected here"
            case .unusual: return "Unusual for area"
            }
        }

        var sortOrder: Int {
            switch self {
            case .unusual: return 0
            case .unknown: return 1
            case .expected: return 2
            }
        }
    }

    let level: Level
    let regionLabel: String?
    let frequencyPercent: Double?

    var displayLabel: String {
        if let frequencyPercent {
            return String(format: "%.1f%% local frequency", frequencyPercent)
        }
        return level.label
    }

    var sortOrder: Int { level.sortOrder }
}
