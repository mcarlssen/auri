import Foundation

enum DetectionSource: String, Codable, Hashable {
    case live
    case file
}

struct BirdDetection: Identifiable, Hashable {
    let id: UUID
    let birdName: String
    let scientificName: String
    let confidence: Double
    let timestamp: Date
    let birdId: Int
    let inferenceMs: Int
    let source: DetectionSource
    let sourceFileName: String?
    let audioOffsetSeconds: Double?
    let rarity: RarityInfo?

    init(
        id: UUID = UUID(),
        birdName: String,
        scientificName: String,
        confidence: Double,
        timestamp: Date = Date(),
        birdId: Int,
        inferenceMs: Int,
        source: DetectionSource = .live,
        sourceFileName: String? = nil,
        audioOffsetSeconds: Double? = nil,
        rarity: RarityInfo? = nil
    ) {
        self.id = id
        self.birdName = birdName
        self.scientificName = scientificName
        self.confidence = confidence
        self.timestamp = timestamp
        self.birdId = birdId
        self.inferenceMs = inferenceMs
        self.source = source
        self.sourceFileName = sourceFileName
        self.audioOffsetSeconds = audioOffsetSeconds
        self.rarity = rarity
    }
}

extension BirdDetection: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case birdName
        case scientificName
        case confidence
        case timestamp
        case birdId
        case inferenceMs
        case source
        case sourceFileName
        case audioOffsetSeconds
        case rarity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        birdName = try container.decode(String.self, forKey: .birdName)
        scientificName = try container.decode(String.self, forKey: .scientificName)
        confidence = try container.decode(Double.self, forKey: .confidence)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        birdId = try container.decode(Int.self, forKey: .birdId)
        inferenceMs = try container.decode(Int.self, forKey: .inferenceMs)
        source = try container.decodeIfPresent(DetectionSource.self, forKey: .source) ?? .live
        sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName)
        audioOffsetSeconds = try container.decodeIfPresent(Double.self, forKey: .audioOffsetSeconds)
        rarity = try container.decodeIfPresent(RarityInfo.self, forKey: .rarity)
    }
}

/// A run of consecutive detections of the same species (and source) collapsed
/// into a single feed entry. A burst of 40 hits for one bird becomes one group
/// carrying all 40 events rather than 40 separate cards.
struct DetectionGroup: Identifiable {
    /// Members newest-first; guaranteed non-empty.
    let detections: [BirdDetection]

    var id: UUID { representative.id }

    /// The newest member — drives name, rarity, and the displayed timestamp.
    var representative: BirdDetection { detections[0] }

    var count: Int { detections.count }

    /// Strongest hit in the run — the most meaningful confidence to surface.
    var peakConfidence: Double {
        detections.map(\.confidence).max() ?? representative.confidence
    }

    /// The member to submit to eBird — the highest-confidence observation.
    var strongest: BirdDetection {
        detections.max(by: { $0.confidence < $1.confidence }) ?? representative
    }

    var firstSeen: Date { detections.map(\.timestamp).min() ?? representative.timestamp }
    var lastSeen: Date { detections.map(\.timestamp).max() ?? representative.timestamp }

    /// Collapse consecutive runs of the same species+source. Non-adjacent runs
    /// stay separate so chronology is preserved (A, B, A → three groups).
    static func grouped(_ detections: [BirdDetection]) -> [DetectionGroup] {
        var groups: [DetectionGroup] = []
        var run: [BirdDetection] = []
        for detection in detections {
            if let last = run.last, last.birdId == detection.birdId, last.source == detection.source {
                run.append(detection)
            } else {
                if !run.isEmpty { groups.append(DetectionGroup(detections: run)) }
                run = [detection]
            }
        }
        if !run.isEmpty { groups.append(DetectionGroup(detections: run)) }
        return groups
    }
}

/// One raw species score from a single recognition window, retained for the
/// Debug accordion's live model-output feed. Captures the threshold in effect
/// at capture time so each row can show whether it would have passed.
struct ModelOutputEntry: Identifiable {
    let id = UUID()
    let birdName: String
    let scientificName: String
    let confidence: Double
    let threshold: Double
    let timestamp: Date

    var passedThreshold: Bool { confidence >= threshold }
}

struct RecognitionResponse: Decodable {
    let bird: String
    let id: Int
    let confidence: Double
    let score: Double
    let timeMs: Int
    let scientificName: String

    enum CodingKeys: String, CodingKey {
        case bird
        case id
        case confidence
        case score
        case timeMs = "time_ms"
        case scientificName = "scientific_name"
    }

    init(
        bird: String,
        id: Int,
        confidence: Double,
        score: Double,
        timeMs: Int,
        scientificName: String
    ) {
        self.bird = bird
        self.id = id
        self.confidence = confidence
        self.score = score
        self.timeMs = timeMs
        self.scientificName = scientificName
    }
}
