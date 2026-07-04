import XCTest
@testable import AuriCore

final class RecognitionPipelineStatsTests: XCTestCase {

    // MARK: - isCriticallyBehind

    func testIsCriticallyBehind_skippedWindowsAloneDoesNotTrigger() {
        // REGRESSION: skippedWindows is a lifetime counter (see the comment on
        // isCriticallyBehind in AudioMeterStats.swift). If it ever participated in this
        // check, it would latch the "critically behind" warning on forever after just a
        // handful of skips over the app's lifetime. It must NOT influence the result.
        var stats = RecognitionPipelineStats()
        stats.skippedWindows = 1000
        XCTAssertFalse(stats.isCriticallyBehind, "skippedWindows must not affect isCriticallyBehind")
    }

    func testIsCriticallyBehind_lastInferenceMsAboveThreshold() {
        var stats = RecognitionPipelineStats()
        stats.lastInferenceMs = 10_001
        XCTAssertTrue(stats.isCriticallyBehind)
    }

    func testIsCriticallyBehind_lastInferenceMsAtThresholdIsNotBehind() {
        // Boundary pin: exactly 10_000ms is not "> 10_000", so this must remain false.
        var stats = RecognitionPipelineStats()
        stats.lastInferenceMs = 10_000
        XCTAssertFalse(stats.isCriticallyBehind)
    }

    func testIsCriticallyBehind_nilLastInferenceMsIsNotBehind() {
        var stats = RecognitionPipelineStats()
        stats.lastInferenceMs = nil
        XCTAssertFalse(stats.isCriticallyBehind)
    }

    // MARK: - secondsSinceLastCompletion

    func testSecondsSinceLastCompletion_nilWhenNoCompletion() {
        let stats = RecognitionPipelineStats()
        XCTAssertNil(stats.secondsSinceLastCompletion)
    }

    // MARK: - isBehindRealtime

    func testIsBehindRealtime_freshOnPaceStateIsFalse() {
        var stats = RecognitionPipelineStats()
        stats.isInFlight = false
        stats.lastCompletedAt = Date(timeIntervalSinceNow: -0.1)
        stats.lastInferenceMs = 100
        XCTAssertFalse(stats.isBehindRealtime)
    }

    func testIsBehindRealtime_clause1_inFlightAndStaleCompletion_isTrue() {
        // Clause 1: isInFlight && (now - lastCompletedAt) > 2.0s.
        // Age is chosen strictly between the clause-1 threshold (2.0s) and the clause-3
        // threshold (2.5s) so this case isolates clause 1 without also tripping clause 3.
        var stats = RecognitionPipelineStats()
        stats.isInFlight = true
        stats.lastCompletedAt = Date(timeIntervalSinceNow: -2.2)
        stats.lastInferenceMs = nil
        XCTAssertTrue(stats.isBehindRealtime)
    }

    func testIsBehindRealtime_clause1_falseWhenNotInFlight() {
        // Same elapsed time as the previous test, but isInFlight is false, so clause 1
        // does not fire. 2.2s is also below the 2.5s clause-3 threshold, so nothing fires.
        var stats = RecognitionPipelineStats()
        stats.isInFlight = false
        stats.lastCompletedAt = Date(timeIntervalSinceNow: -2.2)
        stats.lastInferenceMs = nil
        XCTAssertFalse(stats.isBehindRealtime)
    }

    func testIsBehindRealtime_clause2_slowInferenceIsTrue() {
        var stats = RecognitionPipelineStats()
        stats.isInFlight = false
        stats.lastCompletedAt = Date(timeIntervalSinceNow: -0.1)
        stats.lastInferenceMs = 1_501
        XCTAssertTrue(stats.isBehindRealtime)
    }

    func testIsBehindRealtime_clause2_atThresholdIsFalse() {
        // Boundary pin: exactly 1_500ms is not "> 1_500".
        var stats = RecognitionPipelineStats()
        stats.isInFlight = false
        stats.lastCompletedAt = Date(timeIntervalSinceNow: -0.1)
        stats.lastInferenceMs = 1_500
        XCTAssertFalse(stats.isBehindRealtime)
    }

    func testIsBehindRealtime_clause3_staleCompletionIsTrue() {
        // Clause 3: secondsSinceLastCompletion > 2.5s, independent of isInFlight/lastInferenceMs.
        // Generous 10s margin so this can never flake.
        var stats = RecognitionPipelineStats()
        stats.isInFlight = false
        stats.lastCompletedAt = Date(timeIntervalSinceNow: -10)
        stats.lastInferenceMs = nil
        XCTAssertTrue(stats.isBehindRealtime)
    }

    func testIsBehindRealtime_clause3_recentCompletionIsFalse() {
        var stats = RecognitionPipelineStats()
        stats.isInFlight = false
        stats.lastCompletedAt = Date(timeIntervalSinceNow: -0.1)
        stats.lastInferenceMs = nil
        XCTAssertFalse(stats.isBehindRealtime)
    }
}
