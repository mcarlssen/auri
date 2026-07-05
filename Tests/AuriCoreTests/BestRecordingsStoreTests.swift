import Foundation
import XCTest
@testable import AuriCore

@MainActor
final class BestRecordingsStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func removeIfNeeded(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json")
    }

    private func makeDetection(
        birdId: Int = 1,
        birdName: String = "American Robin",
        scientificName: String = "Turdus migratorius",
        confidence: Double = 0.8
    ) -> BirdDetection {
        BirdDetection(
            birdName: birdName,
            scientificName: scientificName,
            confidence: confidence,
            birdId: birdId,
            inferenceMs: 10
        )
    }

    /// A small non-zero mono window, packed as Float32 bytes the way
    /// `DetectionAudioStore.store` (and thus `consider`) expects. The exact
    /// waveform is irrelevant; the test only cares that it is writable.
    private func makeWindowData(sampleCount: Int = 4_800) -> Data {
        var samples = [Float](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            samples[index] = Float(index % 100) / 100.0 - 0.5
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func makeRecording(
        birdId: Int = 1,
        confidence: Double = 0.8,
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> BestRecording {
        BestRecording(
            birdId: birdId,
            detectionId: UUID(),
            birdName: "American Robin",
            scientificName: "Turdus migratorius",
            confidence: confidence,
            recordedAt: recordedAt,
            fileName: "\(birdId).wav",
            durationSeconds: 3
        )
    }

    // MARK: - shouldReplace policy

    func testShouldReplaceStoresFirstCandidate() {
        XCTAssertTrue(BestRecordingsStore.shouldReplace(existing: nil, candidateConfidence: 0.1))
    }

    func testShouldReplaceWhenStrictlyMoreConfident() {
        let existing = makeRecording(confidence: 0.5)
        XCTAssertTrue(BestRecordingsStore.shouldReplace(existing: existing, candidateConfidence: 0.6))
    }

    func testShouldNotReplaceWhenEqualOrLower() {
        let existing = makeRecording(confidence: 0.5)
        XCTAssertFalse(BestRecordingsStore.shouldReplace(existing: existing, candidateConfidence: 0.5))
        XCTAssertFalse(BestRecordingsStore.shouldReplace(existing: existing, candidateConfidence: 0.4))
    }

    // MARK: - Codable round-trip

    func testBestRecordingCodableRoundTripWithISO8601Dates() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // A whole-second timestamp survives .iso8601 (which drops sub-second
        // precision) exactly, so Equatable comparison holds after the round-trip.
        let original = makeRecording(
            birdId: 42,
            confidence: 0.73,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BestRecording.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, 42)
    }

    // MARK: - Integration (temp directory)

    func testConsiderWritesWavAndIndex() async {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = BestRecordingsStore(directory: dir)
        await store.considerAndWait(
            detection: makeDetection(birdId: 7, confidence: 0.8),
            windowData: makeWindowData(),
            sampleRate: 48_000
        )

        guard let recording = store.recording(forBirdId: 7) else {
            XCTFail("Expected a stored recording after consider")
            return
        }
        XCTAssertEqual(recording.birdId, 7)
        XCTAssertEqual(recording.confidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(recording.fileName, "7.wav")
        XCTAssertGreaterThan(recording.durationSeconds, 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("7.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL(in: dir).path))
    }

    func testHigherConfidenceReplacesAndLowerDoesNot() async {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = BestRecordingsStore(directory: dir)

        await store.considerAndWait(
            detection: makeDetection(birdId: 3, confidence: 0.5),
            windowData: makeWindowData(),
            sampleRate: 48_000
        )
        XCTAssertEqual(store.recording(forBirdId: 3)?.confidence ?? 0, 0.5, accuracy: 0.0001)

        // Strictly more confident: replaces.
        await store.considerAndWait(
            detection: makeDetection(birdId: 3, confidence: 0.9),
            windowData: makeWindowData(),
            sampleRate: 48_000
        )
        XCTAssertEqual(store.recording(forBirdId: 3)?.confidence ?? 0, 0.9, accuracy: 0.0001)

        // Less confident: ignored, the 0.9 clip stays.
        await store.considerAndWait(
            detection: makeDetection(birdId: 3, confidence: 0.6),
            windowData: makeWindowData(),
            sampleRate: 48_000
        )
        XCTAssertEqual(store.recording(forBirdId: 3)?.confidence ?? 0, 0.9, accuracy: 0.0001)
    }

    func testFreshStoreReloadsIndexFromDisk() async {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = BestRecordingsStore(directory: dir)
        await store.considerAndWait(
            detection: makeDetection(birdId: 11, birdName: "Song Sparrow", confidence: 0.77),
            windowData: makeWindowData(),
            sampleRate: 48_000
        )
        XCTAssertNotNil(store.recording(forBirdId: 11))

        // A brand-new store over the same directory must see the persisted clip.
        let reloaded = BestRecordingsStore(directory: dir)
        guard let recording = reloaded.recording(forBirdId: 11) else {
            XCTFail("Expected the reloaded store to read the index from disk")
            return
        }
        XCTAssertEqual(recording.birdId, 11)
        XCTAssertEqual(recording.birdName, "Song Sparrow")
        XCTAssertEqual(recording.confidence, 0.77, accuracy: 0.0001)
        XCTAssertEqual(recording.fileName, "11.wav")
    }

    func testRemoveAllDeletesFilesAndClearsState() async {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = BestRecordingsStore(directory: dir)
        await store.considerAndWait(
            detection: makeDetection(birdId: 5, confidence: 0.8),
            windowData: makeWindowData(),
            sampleRate: 48_000
        )
        XCTAssertFalse(store.recordings.isEmpty)

        store.removeAll()

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("5.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL(in: dir).path))
    }
}
