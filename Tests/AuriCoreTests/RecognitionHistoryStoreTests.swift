import Foundation
import XCTest
@testable import AuriCore

@MainActor
final class RecognitionHistoryStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return dir
    }

    private func historyFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recognition-history.json")
    }

    private func removeIfNeeded(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func make(
        id: UUID = UUID(),
        birdName: String = "Test Bird",
        scientificName: String = "Testus birdus",
        confidence: Double = 0.8,
        timestamp: Date = Date(),
        birdId: Int = 1,
        inferenceMs: Int = 10,
        source: DetectionSource = .live,
        sourceFileName: String? = nil,
        audioOffsetSeconds: Double? = nil,
        rarity: RarityInfo? = nil
    ) -> BirdDetection {
        BirdDetection(
            id: id,
            birdName: birdName,
            scientificName: scientificName,
            confidence: confidence,
            timestamp: timestamp,
            birdId: birdId,
            inferenceMs: inferenceMs,
            source: source,
            sourceFileName: sourceFileName,
            audioOffsetSeconds: audioOffsetSeconds,
            rarity: rarity
        )
    }

    // MARK: - Persistence

    func testAppendAndFlushPersistsToDisk() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        let detection = make(birdName: "American Robin")
        store.append(detection)

        store.flush()

        let fileURL = historyFileURL(in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = RecognitionHistoryStore(directory: dir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, detection.id)
        XCTAssertEqual(reloaded.entries.first?.birdName, "American Robin")
    }

    func testSaveIsDebouncedUntilFlush() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        store.append(make())

        let fileURL = historyFileURL(in: dir)
        // The write is scheduled behind a ~2s debounce; immediately after
        // append, nothing should have hit disk yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Cap

    func testAppendCapsEntriesAndKeepsNewestFirst() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        var lastId: UUID?
        for i in 0..<5_050 {
            let detection = make(id: UUID(), birdName: "Bird \(i)", birdId: i)
            lastId = detection.id
            store.append(detection)
        }

        XCTAssertEqual(store.entries.count, 5_000)
        XCTAssertEqual(store.entries.first?.id, lastId)
    }

    // MARK: - Remove

    func testRemoveByIdDeletesEntryAndPersists() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        let keep = make(birdName: "Keep Me")
        let remove = make(birdName: "Remove Me")
        store.append(keep)
        store.append(remove)

        store.remove(id: remove.id)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, keep.id)

        store.flush()
        let reloaded = RecognitionHistoryStore(directory: dir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, keep.id)
    }

    func testRemoveUnknownIdChangesNothing() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        let detection = make()
        store.append(detection)

        store.remove(id: UUID())

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, detection.id)
    }

    // MARK: - Clear

    func testClearEmptiesAndPersists() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        store.append(make())
        store.append(make())
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)

        store.flush()
        let reloaded = RecognitionHistoryStore(directory: dir)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    // MARK: - entries(forBirdId:)

    func testEntriesForBirdIdFiltersAndSortsNewestFirst() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let robinOld = make(birdName: "Robin", timestamp: base, birdId: 1)
        let robinNew = make(birdName: "Robin", timestamp: base.addingTimeInterval(60), birdId: 1)
        let sparrow = make(birdName: "Sparrow", timestamp: base.addingTimeInterval(30), birdId: 2)

        store.append(robinOld)
        store.append(sparrow)
        store.append(robinNew)

        let robinEntries = store.entries(forBirdId: 1)
        XCTAssertEqual(robinEntries.count, 2)
        XCTAssertEqual(robinEntries.first?.id, robinNew.id)
        XCTAssertEqual(robinEntries.last?.id, robinOld.id)
    }

    // MARK: - speciesSummaries

    func testSpeciesSummariesGroupsSearchesAndSorts() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let robinRarity = RarityInfo(level: .expected, regionLabel: "Home", frequencyPercent: 50)
        let buntingRarity = RarityInfo(level: .unusual, regionLabel: "Home", frequencyPercent: 2)

        // 3 Robin detections, 2 Painted Bunting detections.
        let robin1 = make(birdName: "American Robin", scientificName: "Turdus migratorius", timestamp: base, birdId: 1, rarity: robinRarity)
        let robin2 = make(birdName: "American Robin", scientificName: "Turdus migratorius", timestamp: base.addingTimeInterval(100), birdId: 1, rarity: robinRarity)
        let robin3 = make(birdName: "American Robin", scientificName: "Turdus migratorius", timestamp: base.addingTimeInterval(200), birdId: 1, rarity: robinRarity)
        let bunting1 = make(birdName: "Painted Bunting", scientificName: "Passerina ciris", timestamp: base.addingTimeInterval(50), birdId: 2, rarity: buntingRarity)
        let bunting2 = make(birdName: "Painted Bunting", scientificName: "Passerina ciris", timestamp: base.addingTimeInterval(150), birdId: 2, rarity: buntingRarity)

        for detection in [robin1, robin2, robin3, bunting1, bunting2] {
            store.append(detection)
        }

        // Grouping counts and lastSeen/firstSeen.
        let allSummaries = store.speciesSummaries(search: "", sort: .name)
        XCTAssertEqual(allSummaries.count, 2)

        guard let robinSummary = allSummaries.first(where: { $0.birdId == 1 }) else {
            XCTFail("Missing Robin summary")
            return
        }
        XCTAssertEqual(robinSummary.totalCount, 3)
        XCTAssertEqual(robinSummary.lastSeen, base.addingTimeInterval(200))
        XCTAssertEqual(robinSummary.firstSeen, base)

        guard let buntingSummary = allSummaries.first(where: { $0.birdId == 2 }) else {
            XCTFail("Missing Bunting summary")
            return
        }
        XCTAssertEqual(buntingSummary.totalCount, 2)
        XCTAssertEqual(buntingSummary.lastSeen, base.addingTimeInterval(150))
        XCTAssertEqual(buntingSummary.firstSeen, base.addingTimeInterval(50))

        // Search filter is case-insensitive and matches either common or scientific name.
        let byCommonName = store.speciesSummaries(search: "robin", sort: .name)
        XCTAssertEqual(byCommonName.count, 1)
        XCTAssertEqual(byCommonName.first?.birdId, 1)

        let byScientificName = store.speciesSummaries(search: "passerina", sort: .name)
        XCTAssertEqual(byScientificName.count, 1)
        XCTAssertEqual(byScientificName.first?.birdId, 2)

        let noMatch = store.speciesSummaries(search: "nonexistent", sort: .name)
        XCTAssertTrue(noMatch.isEmpty)

        // Sort by count: Robin (3) should come before Bunting (2).
        let byCount = store.speciesSummaries(search: "", sort: .count)
        XCTAssertEqual(byCount.map(\.birdId), [1, 2])
    }

    // MARK: - uniqueSpecies(since:)

    func testUniqueSpeciesRespectsCutoffAndSortsByName() {
        let dir = makeTempDirectory()
        defer { removeIfNeeded(dir) }

        let store = RecognitionHistoryStore(directory: dir)
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)

        let beforeCutoff = make(birdName: "Zebra Finch", timestamp: cutoff.addingTimeInterval(-100), birdId: 1)
        let afterCutoffZ = make(birdName: "Zebra Finch", timestamp: cutoff.addingTimeInterval(100), birdId: 1)
        let afterCutoffA = make(birdName: "American Robin", timestamp: cutoff.addingTimeInterval(200), birdId: 2)

        store.append(beforeCutoff)
        store.append(afterCutoffZ)
        store.append(afterCutoffA)

        let result = store.uniqueSpecies(since: cutoff)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.birdName), ["American Robin", "Zebra Finch"])

        let zebraSummary = result.first { $0.birdId == 1 }
        XCTAssertEqual(zebraSummary?.detectionCount, 1)
        XCTAssertEqual(zebraSummary?.lastSeen, afterCutoffZ.timestamp)
    }
}
