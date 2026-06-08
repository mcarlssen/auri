import Foundation

struct BirdDetection: Identifiable, Codable, Hashable {
    let id: UUID
    let birdName: String
    let scientificName: String
    let confidence: Double
    let timestamp: Date
    let birdId: Int
    let inferenceMs: Int

    init(
        id: UUID = UUID(),
        birdName: String,
        scientificName: String,
        confidence: Double,
        timestamp: Date = Date(),
        birdId: Int,
        inferenceMs: Int
    ) {
        self.id = id
        self.birdName = birdName
        self.scientificName = scientificName
        self.confidence = confidence
        self.timestamp = timestamp
        self.birdId = birdId
        self.inferenceMs = inferenceMs
    }
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
