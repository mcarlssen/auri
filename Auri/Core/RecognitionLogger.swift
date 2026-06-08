import Foundation

enum RecognitionLogger {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String, category: String = "BirdNet") {
        guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
        let timestamp = formatter.string(from: Date())
        print("[\(category)] \(timestamp) \(message)")
    }
}
