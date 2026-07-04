import Accelerate
import XCTest
@testable import AuriCore

final class ConfidenceRollingEstimatorTests: XCTestCase {

    func testZeroConfidenceNotRecorded() {
        var estimator = ConfidenceRollingEstimator()
        estimator.record(confidence: 0, now: Date())
        XCTAssertNil(estimator.rollingAverageTopConfidence)
        XCTAssertTrue(estimator.recentSamples.isEmpty)
    }

    func testNegativeConfidenceNotRecorded() {
        var estimator = ConfidenceRollingEstimator()
        estimator.record(confidence: -0.5, now: Date())
        XCTAssertNil(estimator.rollingAverageTopConfidence)
        XCTAssertTrue(estimator.recentSamples.isEmpty)
    }

    func testSuggestedThreshold_nilBelowFourSamples() {
        var estimator = ConfidenceRollingEstimator()
        estimator.record(confidence: 0.5, now: Date())
        estimator.record(confidence: 0.5, now: Date())
        estimator.record(confidence: 0.5, now: Date())
        XCTAssertNil(estimator.suggestedThreshold)
    }

    func testSuggestedThreshold_midValueIsUnclamped() {
        // c = 0.4 -> 0.85 * 0.4 = 0.34, which is within [0.10, 0.55], so it passes through.
        var estimator = ConfidenceRollingEstimator()
        for _ in 0..<4 {
            estimator.record(confidence: 0.4, now: Date())
        }
        XCTAssertEqual(estimator.suggestedThreshold ?? -1, 0.34, accuracy: 1e-9)
    }

    func testSuggestedThreshold_lowValueClampsToFloor() {
        // c = 0.05 -> 0.85 * 0.05 = 0.0425, clamped up to the 0.10 floor.
        var estimator = ConfidenceRollingEstimator()
        for _ in 0..<4 {
            estimator.record(confidence: 0.05, now: Date())
        }
        XCTAssertEqual(estimator.suggestedThreshold ?? -1, 0.10, accuracy: 1e-9)
    }

    func testSuggestedThreshold_highValueClampsToCeiling() {
        // c = 0.9 -> 0.85 * 0.9 = 0.765, clamped down to the 0.55 ceiling.
        var estimator = ConfidenceRollingEstimator()
        for _ in 0..<4 {
            estimator.record(confidence: 0.9, now: Date())
        }
        XCTAssertEqual(estimator.suggestedThreshold ?? -1, 0.55, accuracy: 1e-9)
    }

    func testRollingAverageTopConfidence_averagesRecentSamples() {
        var estimator = ConfidenceRollingEstimator()
        for c in [0.2, 0.4, 0.6, 0.8] {
            estimator.record(confidence: c, now: Date())
        }
        XCTAssertEqual(estimator.rollingAverageTopConfidence ?? -1, 0.5, accuracy: 1e-9)
    }

    func testPruning_oldSamplesExcludedFromAverage() {
        var estimator = ConfidenceRollingEstimator()
        let old = Date().addingTimeInterval(-40)
        estimator.record(confidence: 0.9, now: old)
        estimator.record(confidence: 0.9, now: old)
        estimator.record(confidence: 0.6, now: Date())
        // If the two 40s-old samples (0.9, 0.9) were not pruned by the 30s horizon
        // (pruning happens inside record()), the average would be (0.9+0.9+0.6)/3 = 0.8
        // rather than 0.6. This pins that pruning actually removes them.
        XCTAssertEqual(estimator.rollingAverageTopConfidence ?? -1, 0.6, accuracy: 1e-9)
    }

    func testReset_clearsAllSamples() {
        var estimator = ConfidenceRollingEstimator()
        for _ in 0..<5 {
            estimator.record(confidence: 0.5, now: Date())
        }
        estimator.reset()
        XCTAssertNil(estimator.rollingAverageTopConfidence)
        XCTAssertNil(estimator.suggestedThreshold)
        XCTAssertTrue(estimator.recentSamples.isEmpty)
    }
}

final class AudioWindowNormalizerTests: XCTestCase {

    func testDisabled_returnsZeroAndLeavesSamplesUnchanged() {
        var samples: [Float] = [0.1, 0.2, 0.3]
        let original = samples
        let gainDB = AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: false)
        XCTAssertEqual(gainDB, 0)
        XCTAssertEqual(samples, original)
    }

    func testEmptySamples_returnsZero() {
        var samples: [Float] = []
        let gainDB = AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: true)
        XCTAssertEqual(gainDB, 0)
        XCTAssertTrue(samples.isEmpty)
    }

    func testAllZeroSamples_belowMinRMS_returnsZeroUnchanged() {
        var samples = [Float](repeating: 0, count: 100)
        let gainDB = AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: true)
        XCTAssertEqual(gainDB, 0)
        XCTAssertEqual(samples, [Float](repeating: 0, count: 100))
    }

    func testQuietSignal_gainCappedByMaxGainLinear() {
        var samples = [Float](repeating: 0.001, count: 1000)
        let gainDB = AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: true)

        // gain = min(maxGainLinear, targetRMS / rms) = min(16, 0.025 / 0.001 = 25) = 16,
        // so the applied gain is capped by maxGainLinear rather than reaching targetRMS.
        let expectedGainLinear: Float = AudioWindowNormalizer.maxGainLinear
        let expectedNewRMS: Float = min(AudioWindowNormalizer.targetRMS, 0.001 * expectedGainLinear)
        XCTAssertEqual(expectedNewRMS, 0.016, accuracy: 1e-6)

        var newRMS: Float = 0
        vDSP_rmsqv(samples, 1, &newRMS, vDSP_Length(samples.count))
        XCTAssertEqual(newRMS, expectedNewRMS, accuracy: 1e-4)
        XCTAssertEqual(gainDB, 20 * log10(expectedGainLinear), accuracy: 0.1)
    }

    func testSignalAlreadyAtTargetRMS_noGainApplied() {
        var samples = [Float](repeating: 0.5, count: 1000)
        let original = samples
        let gainDB = AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: true)
        // gain = min(16, 0.025 / 0.5 = 0.05) = 0.05, which is <= 1.001, so the guard
        // bails out and no gain is applied at all.
        XCTAssertEqual(gainDB, 0)
        XCTAssertEqual(samples, original)
    }

    func testClipping_largeOutlierClampedToPositiveOne() {
        var samples = [Float](repeating: 1e-6, count: 10_000)
        samples[5000] = 0.5
        // The overall rms is diluted by the 10,000-sample array (~0.005), well below
        // targetRMS (0.025), so a gain of roughly 5x is applied. That gain would push the
        // single 0.5 outlier to ~2.5, which must be hard-clipped down to exactly 1.0.
        _ = AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: true)
        XCTAssertEqual(samples[5000], 1.0)
        for sample in samples {
            XCTAssertLessThanOrEqual(sample, 1.0)
            XCTAssertGreaterThanOrEqual(sample, -1.0)
        }
    }
}
