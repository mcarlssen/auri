import Foundation
import XCTest
@testable import AuriCore

final class BirdDetectionCodableTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureURL(named name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
            return url
        }
        // Defensive fallback in case the resource bundle flattens the directory structure.
        return Bundle.module.url(forResource: name, withExtension: "json")
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func isoDate(_ string: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: string) else {
            XCTFail("Failed to parse fixture date: \(string)")
            return Date()
        }
        return date
    }

    // MARK: - Current format

    func testDecodesCurrentFormatFixture() throws {
        guard let url = fixtureURL(named: "history-current-format") else {
            XCTFail("Missing fixture history-current-format.json")
            return
        }
        let data = try Data(contentsOf: url)
        let detections = try makeDecoder().decode([BirdDetection].self, from: data)

        XCTAssertEqual(detections.count, 3)

        // Entry 1: live source, no rarity.
        let first = detections[0]
        XCTAssertEqual(first.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(first.birdName, "American Robin")
        XCTAssertEqual(first.scientificName, "Turdus migratorius")
        XCTAssertEqual(first.confidence, 0.87, accuracy: 0.0001)
        XCTAssertEqual(first.timestamp, isoDate("2026-07-01T12:00:00Z"))
        XCTAssertEqual(first.birdId, 101)
        XCTAssertEqual(first.inferenceMs, 42)
        XCTAssertEqual(first.source, .live)
        XCTAssertNil(first.sourceFileName)
        XCTAssertNil(first.audioOffsetSeconds)
        XCTAssertNil(first.rarity)

        // Entry 2: file source with sourceFileName, audioOffsetSeconds, and unusual rarity.
        let second = detections[1]
        XCTAssertEqual(second.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(second.birdName, "Painted Bunting")
        XCTAssertEqual(second.source, .file)
        XCTAssertEqual(second.sourceFileName, "backyard-recording.wav")
        XCTAssertEqual(second.audioOffsetSeconds ?? -1, 12.5, accuracy: 0.0001)
        XCTAssertEqual(second.rarity?.level, .unusual)
        XCTAssertEqual(second.rarity?.regionLabel, "Pacific Northwest")
        XCTAssertEqual(second.rarity?.frequencyPercent ?? -1, 1.2, accuracy: 0.0001)

        // Entry 3: live source with expected rarity, no optional file fields.
        let third = detections[2]
        XCTAssertEqual(third.id, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(third.birdName, "Black-capped Chickadee")
        XCTAssertEqual(third.source, .live)
        XCTAssertNil(third.sourceFileName)
        XCTAssertNil(third.audioOffsetSeconds)
        XCTAssertEqual(third.rarity?.level, .expected)
        XCTAssertEqual(third.rarity?.regionLabel, "Pacific Northwest")
        XCTAssertEqual(third.rarity?.frequencyPercent ?? -1, 48.0, accuracy: 0.0001)
    }

    // MARK: - Legacy format

    /// Guards against schema changes orphaning previously-persisted user history:
    /// entries written before `source`/`sourceFileName`/`audioOffsetSeconds`/`rarity`
    /// existed must still decode, defaulting the newer fields sensibly.
    func testDecodesLegacyFormatFixtureWithDefaults() throws {
        guard let url = fixtureURL(named: "history-legacy-format") else {
            XCTFail("Missing fixture history-legacy-format.json")
            return
        }
        let data = try Data(contentsOf: url)
        let detections = try makeDecoder().decode([BirdDetection].self, from: data)

        XCTAssertEqual(detections.count, 1)
        let entry = detections[0]
        XCTAssertEqual(entry.birdName, "Song Sparrow")
        XCTAssertEqual(entry.source, .live)
        XCTAssertNil(entry.sourceFileName)
        XCTAssertNil(entry.audioOffsetSeconds)
        XCTAssertNil(entry.rarity)
        // History written before verification existed must default to unverified.
        XCTAssertEqual(entry.verification, .unverified)
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTripPreservesAllFields() throws {
        let fixedId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let fixedDate = isoDate("2026-01-15T08:45:30Z")
        let original = BirdDetection(
            id: fixedId,
            birdName: "Northern Cardinal",
            scientificName: "Cardinalis cardinalis",
            confidence: 0.912,
            timestamp: fixedDate,
            birdId: 555,
            inferenceMs: 64,
            source: .file,
            sourceFileName: "morning-walk.m4a",
            audioOffsetSeconds: 3.75,
            rarity: RarityInfo(level: .unusual, regionLabel: "Northeast", frequencyPercent: 4.5)
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(BirdDetection.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.birdName, original.birdName)
        XCTAssertEqual(decoded.scientificName, original.scientificName)
        XCTAssertEqual(decoded.confidence, original.confidence, accuracy: 0.0001)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.birdId, original.birdId)
        XCTAssertEqual(decoded.inferenceMs, original.inferenceMs)
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(decoded.sourceFileName, original.sourceFileName)
        XCTAssertEqual(decoded.audioOffsetSeconds ?? -1, original.audioOffsetSeconds ?? -2, accuracy: 0.0001)
        XCTAssertEqual(decoded.rarity?.level, original.rarity?.level)
        XCTAssertEqual(decoded.rarity?.regionLabel, original.rarity?.regionLabel)
        XCTAssertEqual(decoded.rarity?.frequencyPercent ?? -1, original.rarity?.frequencyPercent ?? -2, accuracy: 0.0001)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Verification

    func testRoundTripPreservesVerificationStates() throws {
        for state in [DetectionVerification.confirmed, .rejected, .unverified] {
            let original = BirdDetection(
                birdName: "American Robin",
                scientificName: "Turdus migratorius",
                confidence: 0.8,
                // Whole-second timestamp: the .iso8601 codec drops fractional
                // seconds, so a defaulted Date() would come back truncated and
                // break the full-struct equality below.
                timestamp: isoDate("2026-07-01T12:00:00Z"),
                birdId: 101,
                inferenceMs: 20,
                verification: state
            )
            let data = try makeEncoder().encode(original)
            let decoded = try makeDecoder().decode(BirdDetection.self, from: data)
            XCTAssertEqual(decoded.verification, state)
            XCTAssertEqual(decoded, original)
        }
    }

    // MARK: - DetectionGroup verification aggregation

    private func detection(_ verification: DetectionVerification) -> BirdDetection {
        BirdDetection(
            birdName: "American Robin",
            scientificName: "Turdus migratorius",
            confidence: 0.8,
            birdId: 101,
            inferenceMs: 20,
            verification: verification
        )
    }

    func testGroupVerificationAnyConfirmedWins() {
        let group = DetectionGroup(detections: [
            detection(.confirmed),
            detection(.rejected),
            detection(.unverified)
        ])
        XCTAssertEqual(group.verification, .confirmed)
    }

    func testGroupVerificationAllRejectedIsRejected() {
        let group = DetectionGroup(detections: [detection(.rejected), detection(.rejected)])
        XCTAssertEqual(group.verification, .rejected)
    }

    func testGroupVerificationMixedRejectedAndUnverifiedIsUnverified() {
        let group = DetectionGroup(detections: [detection(.rejected), detection(.unverified)])
        XCTAssertEqual(group.verification, .unverified)
    }

    func testGroupVerificationAllUnverifiedIsUnverified() {
        let group = DetectionGroup(detections: [detection(.unverified), detection(.unverified)])
        XCTAssertEqual(group.verification, .unverified)
    }
}
