import Foundation

enum DotEnv {
    static func value(for key: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }

        for url in candidateFiles() {
            if let value = parse(url: url, key: key) {
                return value
            }
        }
        return nil
    }

    private static func candidateFiles() -> [URL] {
        var files: [URL] = []
        let coreDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let auriDirectory = coreDirectory.deletingLastPathComponent()

        files.append(auriDirectory.appendingPathComponent("UI/.env"))
        files.append(auriDirectory.appendingPathComponent(".env"))

        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            files.append(support.appendingPathComponent("Auri/.env"))
        }

        return files
    }

    private static func parse(url: URL, key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == key else { continue }
            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
