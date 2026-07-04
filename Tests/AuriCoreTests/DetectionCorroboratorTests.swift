import XCTest
@testable import AuriCore

final class DetectionCorroboratorTests: XCTestCase {
    // BirdNET's window is 3 seconds; corroborating windows must fall inside it.
    private let horizon: TimeInterval = 3.0

    func testOverlapOffPassesThroughOnFirstWindow() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        // required == 1 mirrors overlap-off, where there is one look per window.
        let result = corroborator.corroborate(speciesId: 1, confidence: 0.9, required: 1)
        XCTAssertEqual(result, 0.9)
    }

    func testSingleWindowIsNotCorroboratedWhenTwoRequired() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        XCTAssertNil(corroborator.corroborate(speciesId: 1, confidence: 0.9, required: 2))
    }

    func testTwoWindowsWithinHorizonQualifyWithMaxConfidence() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        let start = Date()
        XCTAssertNil(corroborator.corroborate(speciesId: 1, confidence: 0.72, required: 2, now: start))
        let second = corroborator.corroborate(
            speciesId: 1, confidence: 0.81, required: 2, now: start.addingTimeInterval(1.5)
        )
        XCTAssertEqual(second, 0.81, "aggregated confidence is the max of corroborating windows")
    }

    func testMaxConfidenceKeepsEarlierWindowWhenItIsHigher() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        let start = Date()
        _ = corroborator.corroborate(speciesId: 1, confidence: 0.88, required: 2, now: start)
        let second = corroborator.corroborate(
            speciesId: 1, confidence: 0.70, required: 2, now: start.addingTimeInterval(1.0)
        )
        XCTAssertEqual(second, 0.88)
    }

    func testWindowsOutsideHorizonDoNotCorroborate() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        let start = Date()
        _ = corroborator.corroborate(speciesId: 1, confidence: 0.9, required: 2, now: start)
        // A second look arriving after the horizon has elapsed is a fresh, lone
        // observation — the stale one is pruned, so it must not qualify.
        let later = corroborator.corroborate(
            speciesId: 1, confidence: 0.9, required: 2, now: start.addingTimeInterval(horizon + 0.5)
        )
        XCTAssertNil(later)
    }

    func testDistinctSpeciesDoNotCorroborateEachOther() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        let now = Date()
        XCTAssertNil(corroborator.corroborate(speciesId: 1, confidence: 0.9, required: 2, now: now))
        XCTAssertNil(corroborator.corroborate(speciesId: 2, confidence: 0.9, required: 2, now: now))
    }

    func testResetClearsObservations() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        let now = Date()
        _ = corroborator.corroborate(speciesId: 1, confidence: 0.9, required: 2, now: now)
        corroborator.reset()
        // After reset the prior window is gone, so the next lone window can't qualify.
        XCTAssertNil(corroborator.corroborate(speciesId: 1, confidence: 0.9, required: 2, now: now))
    }

    func testSustainedCallKeepsQualifyingOnSubsequentWindows() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        let start = Date()
        XCTAssertNil(
            corroborator.corroborate(speciesId: 1, confidence: 0.8, required: 2, now: start)
        )
        XCTAssertNotNil(
            corroborator.corroborate(speciesId: 1, confidence: 0.8, required: 2, now: start.addingTimeInterval(1.5))
        )
        XCTAssertNotNil(
            corroborator.corroborate(speciesId: 1, confidence: 0.8, required: 2, now: start.addingTimeInterval(3.0))
        )
    }

    func testNonPositiveRequiredIsTreatedAsOne() {
        var corroborator = DetectionCorroborator(horizonSeconds: horizon)
        // Defensive: a zero/negative requirement must still emit, never trap.
        XCTAssertEqual(corroborator.corroborate(speciesId: 1, confidence: 0.6, required: 0), 0.6)
    }
}
