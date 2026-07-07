import Foundation
import XCTest
@testable import AuriCore

final class DailyDigestBuilderTests: XCTestCase {

    // MARK: - Helpers

    /// Fixed UTC gregorian calendar so bin/day math is machine-independent.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func detection(
        birdId: Int,
        name: String,
        at date: Date,
        source: DetectionSource = .live
    ) -> BirdDetection {
        BirdDetection(
            birdName: name,
            scientificName: "Sci \(birdId)",
            confidence: 0.9,
            timestamp: date,
            birdId: birdId,
            inferenceMs: 10,
            source: source
        )
    }

    // MARK: - Quiet day

    func testEmptyHistoryReturnsNil() {
        XCTAssertNil(DailyDigestBuilder.summarize(entries: [], day: date(2026, 7, 4, 9), calendar: calendar))
    }

    func testDayWithoutLiveDetectionsReturnsNil() {
        // A file-analysis entry on the target day plus a live entry on another day:
        // neither contributes, so there is nothing to summarize.
        let entries = [
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 4, 9), source: .file),
            detection(birdId: 2, name: "Jay", at: date(2026, 7, 3, 9), source: .live)
        ]
        XCTAssertNil(DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 9), calendar: calendar))
    }

    // MARK: - Counts scoped to day + live source

    func testCountsScopedToTargetDayAndLiveSource() {
        let entries = [
            // Target day, live: 2 species, 3 detections.
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 4, 7)),
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 4, 8)),
            detection(birdId: 2, name: "Jay", at: date(2026, 7, 4, 15)),
            // Target day but file source — excluded.
            detection(birdId: 3, name: "Crow", at: date(2026, 7, 4, 9), source: .file),
            // Live but a different day — excluded.
            detection(birdId: 4, name: "Wren", at: date(2026, 7, 5, 7))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 12), calendar: calendar)
        XCTAssertEqual(summary?.speciesCount, 2)
        XCTAssertEqual(summary?.detectionCount, 3)
        XCTAssertEqual(summary?.day, date(2026, 7, 4, 0))
    }

    // MARK: - New species

    func testNewSpeciesAreFirstEverLiveOnly() {
        let entries = [
            // Heard last week AND today → not new.
            detection(birdId: 1, name: "Robin", at: date(2026, 6, 27, 8)),
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 4, 8)),
            // First-ever detection is today → new.
            detection(birdId: 2, name: "Brown Creeper", at: date(2026, 7, 4, 9))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 12), calendar: calendar)
        XCTAssertEqual(summary?.newSpeciesNames, ["Brown Creeper"])
    }

    func testNewSpeciesOrderedByFirstDetectionOfDay() {
        // Supplied out of chronological order; the names should come back in the
        // order the birds were first heard that day.
        let entries = [
            detection(birdId: 2, name: "Jay", at: date(2026, 7, 4, 10)),
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 4, 6)),
            detection(birdId: 3, name: "Wren", at: date(2026, 7, 4, 8))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 12), calendar: calendar)
        XCTAssertEqual(summary?.newSpeciesNames, ["Robin", "Wren", "Jay"])
    }

    func testFileHistoryDoesNotBlockNewness() {
        // Only live history counts toward "first-ever", so a prior file detection
        // must not stop today's first live detection from being new.
        let entries = [
            detection(birdId: 1, name: "Robin", at: date(2026, 6, 27, 8), source: .file),
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 4, 8), source: .live)
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 12), calendar: calendar)
        XCTAssertEqual(summary?.newSpeciesNames, ["Robin"])
    }

    func testLaterDetectionDoesNotUnmarkNewSpecies() {
        // First heard today, heard again next week: earliest-ever is still today,
        // so it stays new for today's digest.
        let entries = [
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 4, 8)),
            detection(birdId: 1, name: "Robin", at: date(2026, 7, 11, 8))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 12), calendar: calendar)
        XCTAssertEqual(summary?.newSpeciesNames, ["Robin"])
    }

    // MARK: - Busiest 2-hour bin

    func testBusiestHourLabelMorning() {
        let entries = [
            detection(birdId: 1, name: "A", at: date(2026, 7, 4, 6, 5)),
            detection(birdId: 2, name: "B", at: date(2026, 7, 4, 7, 10)),
            detection(birdId: 3, name: "C", at: date(2026, 7, 4, 7, 50)),
            detection(birdId: 4, name: "D", at: date(2026, 7, 4, 15))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 20), calendar: calendar)
        XCTAssertEqual(summary?.busiestHourLabel, "6–8 AM")
    }

    func testBusiestHourLabelAfternoon() {
        let entries = [
            detection(birdId: 1, name: "A", at: date(2026, 7, 4, 16)),
            detection(birdId: 2, name: "B", at: date(2026, 7, 4, 17))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 20), calendar: calendar)
        XCTAssertEqual(summary?.busiestHourLabel, "4–6 PM")
    }

    func testBusiestHourLabelMidnightBin() {
        // Hours 0 and 1 bucket into "12–2 AM".
        let entries = [
            detection(birdId: 1, name: "A", at: date(2026, 7, 4, 0, 30)),
            detection(birdId: 2, name: "B", at: date(2026, 7, 4, 1, 15))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 20), calendar: calendar)
        XCTAssertEqual(summary?.busiestHourLabel, "12–2 AM")
    }

    func testBusiestHourLabelNoonBin() {
        // Hours 12 and 13 bucket into "12–2 PM".
        let entries = [
            detection(birdId: 1, name: "A", at: date(2026, 7, 4, 12, 10)),
            detection(birdId: 2, name: "B", at: date(2026, 7, 4, 13, 45))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 20), calendar: calendar)
        XCTAssertEqual(summary?.busiestHourLabel, "12–2 PM")
    }

    func testBusiestHourTieResolvesToEarlierBin() {
        // Two in the 6–8 AM bin, two in the 2–4 PM bin: the earlier bin wins.
        let entries = [
            detection(birdId: 1, name: "A", at: date(2026, 7, 4, 6)),
            detection(birdId: 2, name: "B", at: date(2026, 7, 4, 7)),
            detection(birdId: 3, name: "C", at: date(2026, 7, 4, 14)),
            detection(birdId: 4, name: "D", at: date(2026, 7, 4, 15))
        ]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 20), calendar: calendar)
        XCTAssertEqual(summary?.busiestHourLabel, "6–8 AM")
    }

    func testBusiestHourNilForSingleDetection() {
        // One detection still yields a (non-nil) summary, but no busiest window.
        let entries = [detection(birdId: 1, name: "A", at: date(2026, 7, 4, 6))]
        let summary = DailyDigestBuilder.summarize(entries: entries, day: date(2026, 7, 4, 12), calendar: calendar)
        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.busiestHourLabel)
        XCTAssertEqual(summary?.speciesCount, 1)
        XCTAssertEqual(summary?.detectionCount, 1)
    }
}
