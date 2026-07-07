import Foundation

struct SessionSpeciesSummary: Identifiable, Hashable {
    let birdId: Int
    let birdName: String
    let scientificName: String
    let detectionCount: Int
    let lastSeen: Date

    var id: Int { birdId }
}

struct SpeciesHistorySummary: Identifiable, Hashable {
    let birdId: Int
    let birdName: String
    let scientificName: String
    let totalCount: Int
    let lastSeen: Date
    let firstSeen: Date
    let rarity: RarityInfo?

    var id: Int { birdId }
}

enum HistorySortOption: String, CaseIterable, Identifiable {
    case date
    case count
    case rarity
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return "Most recent"
        case .count: return "Recognition count"
        case .rarity: return "Rarity"
        case .name: return "Name"
        }
    }
}

@MainActor
final class RecognitionHistoryStore: ObservableObject {
    @Published private(set) var entries: [BirdDetection] = []

    private let maxEntries = 5_000
    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?
    private static let saveDebounceNanoseconds: UInt64 = 2_000_000_000

    init(directory: URL? = nil) {
        let resolvedDirectory: URL
        if let directory {
            resolvedDirectory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolvedDirectory = support.appendingPathComponent("Auri", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        fileURL = resolvedDirectory.appendingPathComponent("recognition-history.json")
        load()
    }

    func append(_ detection: BirdDetection) {
        entries.insert(detection, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    func remove(id: UUID) {
        let originalCount = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != originalCount else { return }
        scheduleSave()
    }

    /// Apply a verification state to every entry whose id is in `ids` — a grouped
    /// feed entry confirms or rejects all its members at once. No-op (and no
    /// write) when nothing actually changes, mirroring `remove(id:)`.
    func setVerification(_ verification: DetectionVerification, forIds ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var changed = false
        entries = entries.map { entry in
            guard ids.contains(entry.id), entry.verification != verification else { return entry }
            changed = true
            return entry.withVerification(verification)
        }
        guard changed else { return }
        scheduleSave()
    }

    /// Write any pending changes immediately; call before the app terminates.
    func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
    }

    func entries(forBirdId birdId: Int) -> [BirdDetection] {
        entries
            .filter { $0.birdId == birdId }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func speciesSummaries(search: String, sort: HistorySortOption, since: Date? = nil) -> [SpeciesHistorySummary] {
        // Rejected entries are "not that bird", so they must not count toward the
        // heard species list, its counts, or first/last-seen. They stay in
        // `entries`, so the user can still see and un-reject them.
        var grouped: [Int: [BirdDetection]] = [:]
        for entry in entries where entry.verification != .rejected && (since == nil || entry.timestamp >= since!) {
            grouped[entry.birdId, default: []].append(entry)
        }

        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var summaries = grouped.values.compactMap { detections -> SpeciesHistorySummary? in
            guard let first = detections.first else { return nil }
            let summary = SpeciesHistorySummary(
                birdId: first.birdId,
                birdName: first.birdName,
                scientificName: first.scientificName,
                totalCount: detections.count,
                lastSeen: detections.map(\.timestamp).max() ?? first.timestamp,
                firstSeen: detections.map(\.timestamp).min() ?? first.timestamp,
                rarity: detections.compactMap(\.rarity).first
            )
            return summary
        }

        if !trimmedSearch.isEmpty {
            summaries = summaries.filter {
                $0.birdName.localizedCaseInsensitiveContains(trimmedSearch)
                    || $0.scientificName.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }

        switch sort {
        case .date:
            summaries.sort { $0.lastSeen > $1.lastSeen }
        case .count:
            summaries.sort { $0.totalCount > $1.totalCount }
        case .rarity:
            summaries.sort {
                let left = $0.rarity?.sortOrder ?? RarityInfo.Level.unknown.sortOrder
                let right = $1.rarity?.sortOrder ?? RarityInfo.Level.unknown.sortOrder
                if left == right { return $0.lastSeen > $1.lastSeen }
                return left < right
            }
        case .name:
            summaries.sort {
                $0.birdName.localizedCaseInsensitiveCompare($1.birdName) == .orderedAscending
            }
        }

        return summaries
    }

    /// Lifetime detections of a species, excluding rejected ones — the "★ First"
    /// badge derives from this being 1, so it stays consistent as entries are
    /// confirmed or rejected.
    func lifetimeCount(for birdId: Int) -> Int {
        entries.filter { $0.birdId == birdId && $0.verification != .rejected }.count
    }

    /// How many of a species' entries the user has explicitly confirmed vs.
    /// rejected. Unlike the heard-count methods, this counts rejected entries —
    /// they are the whole point of the "· N rejected" summary.
    func verificationCounts(forBirdId birdId: Int) -> (confirmed: Int, rejected: Int) {
        var confirmed = 0
        var rejected = 0
        for entry in entries where entry.birdId == birdId {
            switch entry.verification {
            case .confirmed: confirmed += 1
            case .rejected: rejected += 1
            case .unverified: break
            }
        }
        return (confirmed, rejected)
    }

    func uniqueSpecies(since date: Date) -> [SessionSpeciesSummary] {
        var grouped: [Int: [BirdDetection]] = [:]
        for entry in entries where entry.verification != .rejected && entry.timestamp >= date {
            grouped[entry.birdId, default: []].append(entry)
        }

        return grouped.values.compactMap { detections -> SessionSpeciesSummary? in
            guard let first = detections.first else { return nil }
            return SessionSpeciesSummary(
                birdId: first.birdId,
                birdName: first.birdName,
                scientificName: first.scientificName,
                detectionCount: detections.count,
                lastSeen: detections.map(\.timestamp).max() ?? first.timestamp
            )
        }
        .sorted {
            $0.birdName.localizedCaseInsensitiveCompare($1.birdName) == .orderedAscending
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([BirdDetection].self, from: data)) ?? []
    }

    /// Serializing 5k pretty-printed entries per detection is wasteful during a
    /// burst of recognitions; coalesce writes behind a short debounce instead.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.writeToDisk()
        }
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
