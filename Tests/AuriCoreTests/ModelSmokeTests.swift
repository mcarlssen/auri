import CoreML
import Foundation
import XCTest
@testable import AuriCore

/// Tier-2 integration smoke tests that run the *real* BirdNET Core ML model on
/// CPU. These require the model + labels to be present in the checkout (they are
/// on the macos-15 CI runner); forks without the model skip instead of failing.
///
/// Compute is pinned to `.cpuOnly` so results are deterministic (ANE/GPU are not).
/// Total predictions across the suite are kept to ~5 to keep CI time sane.
final class ModelSmokeTests: XCTestCase {

    // MARK: - Shared, compile-once model

    private struct SharedModel {
        let model: MLModel
        let inputName: String
        let labels: [BirdNetCoreMLRecognizer.SpeciesLabel]
        let labelsURL: URL
    }

    private static var cached: SharedModel?
    private static var cachedError: Error?
    private static var didAttempt = false
    private static let attemptLock = NSLock()

    /// Walks up from this test file until a directory containing `Auri.xcodeproj`
    /// is found (bounded to 10 levels). XCTFail + nil if not found.
    private func repoRoot(file: StaticString = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("Auri.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("Could not locate repo root (Auri.xcodeproj) above \(file)")
        return nil
    }

    private func modelURL() -> URL? {
        repoRoot()?
            .appendingPathComponent("Auri/Resources/BirdNet/audio-model-fp16.mlpackage")
    }

    private func labelsURL() -> URL? {
        repoRoot()?
            .appendingPathComponent("Auri/Resources/BirdNet/labels/en_us.txt")
    }

    private static func build(modelURL: URL, labelsURL: URL) throws -> SharedModel {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        // Use the synchronous `MLModel.compileModel(at:)` (throws, non-async). It is
        // deprecated in favor of the async overload on recent SDKs but remains
        // available on macOS, and keeps this non-async static simple and free of
        // any semaphore/Task bridging. Deprecation is a warning, not a build error.
        let compiled = try MLModel.compileModel(at: modelURL)
        let model = try MLModel(contentsOf: compiled, configuration: config)
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw NSError(
                domain: "ModelSmokeTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "model has no inputs"]
            )
        }
        let labels = try BirdNetCoreMLRecognizer.loadSpeciesLabels(from: labelsURL)
        return SharedModel(model: model, inputName: inputName, labels: labels, labelsURL: labelsURL)
    }

    /// Returns the shared model, compiling it exactly once. Skips (not fails) when
    /// the model is absent from the checkout; rethrows genuine load/compile errors.
    private func sharedModel() throws -> SharedModel {
        guard let modelURL = modelURL(), let labelsURL = labelsURL() else {
            throw XCTSkip("repo root not found")
        }
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelURL.path),
            "model not in checkout"
        )

        Self.attemptLock.lock()
        defer { Self.attemptLock.unlock() }
        if Self.didAttempt {
            if let error = Self.cachedError { throw error }
            return Self.cached!
        }
        Self.didAttempt = true
        do {
            let built = try Self.build(modelURL: modelURL, labelsURL: labelsURL)
            Self.cached = built
            return built
        } catch {
            Self.cachedError = error
            throw error
        }
    }

    // MARK: - Prediction helpers

    private func topPredictions(
        _ samples: [Float], shared: SharedModel, limit: Int
    ) throws -> [(index: Int, score: Double)] {
        let provider = try BirdNetCoreMLRecognizer.makeInputProvider(
            samples: samples, featureName: shared.inputName
        )
        let output = try shared.model.prediction(from: provider)
        guard let name = output.featureNames.first,
              let scores = output.featureValue(for: name)?.multiArrayValue else {
            XCTFail("model produced no output feature")
            return []
        }
        return BirdNetCoreMLRecognizer.topPredictions(from: scores, limit: limit)
    }

    /// Linear frequency sweep (chirp) with an analytically-integrated phase, so it
    /// is bit-for-bit reproducible for a given set of parameters.
    private func linearSweep(
        from f0: Float, to f1: Float, amplitude: Float, count: Int, sampleRate: Float
    ) -> [Float] {
        guard count > 0 else { return [] }
        let dt = 1 / sampleRate
        let duration = Float(count) * dt
        return (0..<count).map { index in
            let t = Float(index) * dt
            // phase(t) = 2π · (f0·t + ½·(f1 - f0)/T · t²)
            let phase = 2 * Float.pi * (f0 * t + 0.5 * (f1 - f0) / duration * t * t)
            return amplitude * sinf(phase)
        }
    }

    // MARK: - Tests

    func testModelLoadsAndDescribesInput() throws {
        let shared = try sharedModel()
        let inputs = shared.model.modelDescription.inputDescriptionsByName
        XCTAssertFalse(inputs.isEmpty, "model must expose at least one input")

        let description = inputs[shared.inputName]
        XCTAssertNotNil(description)

        // Defensive: only assert the window size when a multiArray constraint is present.
        if let constraint = description?.multiArrayConstraint {
            let shape = constraint.shape.map { $0.intValue }
            // BirdNET consumes a fixed 3 s window at 48 kHz => 144_000 samples.
            XCTAssertEqual(
                shape.last, BirdNetCoreMLRecognizer.windowSamples,
                "model input last dimension should equal windowSamples (144_000)"
            )
        }
    }

    func testLabelCountMatchesModelOutput() throws {
        // Catches model/labels version skew: the label file must have exactly one
        // entry per output score, or detection indices map to the wrong species.
        let shared = try sharedModel()
        let silence = [Float](repeating: 0, count: BirdNetCoreMLRecognizer.windowSamples)
        let provider = try BirdNetCoreMLRecognizer.makeInputProvider(
            samples: silence, featureName: shared.inputName
        )
        let output = try shared.model.prediction(from: provider)
        guard let name = output.featureNames.first,
              let scores = output.featureValue(for: name)?.multiArrayValue else {
            XCTFail("model produced no output feature")
            return
        }
        let labels = try BirdNetCoreMLRecognizer.loadSpeciesLabels(from: shared.labelsURL)
        XCTAssertEqual(labels.count, scores.count, "label count must equal model output score count")
    }

    func testSilenceProducesNoConfidentDetection() throws {
        let shared = try sharedModel()
        var silence = [Float](repeating: 0, count: BirdNetCoreMLRecognizer.windowSamples)

        // applyAutoGain returns 0 for pure silence: RMS is 0, which fails the
        // `rms > minRMS` guard, so no gain is applied.
        let gain = AudioWindowNormalizer.applyAutoGain(to: &silence, enabled: true)
        XCTAssertEqual(gain, 0, "silence must not be amplified")

        let top = try topPredictions(silence, shared: shared, limit: 10)
        XCTAssertFalse(top.isEmpty)
        XCTAssertLessThan(top[0].score, 0.5, "silence must not yield a confident detection")
        for prediction in top {
            XCTAssertFalse(prediction.score.isNaN, "scores must never be NaN")
        }
    }

    func testDeterministicOnCPU() throws {
        // cpuOnly execution is deterministic; ANE/GPU paths would not guarantee
        // bit-identical scores, so this pins the CPU contract.
        let shared = try sharedModel()
        let chirp = linearSweep(
            from: 2_000, to: 8_000, amplitude: 0.5,
            count: BirdNetCoreMLRecognizer.windowSamples, sampleRate: 48_000
        )

        let first = try topPredictions(chirp, shared: shared, limit: 5)
        let second = try topPredictions(chirp, shared: shared, limit: 5)

        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(second.count, 5)
        for i in 0..<first.count {
            XCTAssertEqual(first[i].index, second[i].index, "top-5 index mismatch at rank \(i)")
            XCTAssertEqual(first[i].score, second[i].score, accuracy: 1e-5, "score mismatch at rank \(i)")
        }
    }

    func testFullPipelineShape() throws {
        let shared = try sharedModel()

        // Chirp captured at 44.1 kHz; 144_000 * 44_100 / 48_000 = 132_300 samples.
        let sourceRate = 44_100
        let sourceCount = BirdNetCoreMLRecognizer.windowSamples * sourceRate / BirdNetCoreMLRecognizer.modelSampleRate
        XCTAssertEqual(sourceCount, 132_300)

        let chirp = linearSweep(
            from: 2_000, to: 8_000, amplitude: 0.5,
            count: sourceCount, sampleRate: Float(sourceRate)
        )

        // resample -> fitWindow -> autoGain -> predict, mirroring recognize().
        var samples = BirdNetCoreMLRecognizer.resample(chirp, from: sourceRate, to: BirdNetCoreMLRecognizer.modelSampleRate)
        samples = BirdNetCoreMLRecognizer.fitWindow(samples)
        XCTAssertEqual(samples.count, BirdNetCoreMLRecognizer.windowSamples)
        AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: true)

        let top = try topPredictions(samples, shared: shared, limit: 10)
        XCTAssertFalse(top.isEmpty)

        let labelCount = shared.labels.count
        for i in top.indices {
            // topPredictions returns descending order => strictly non-increasing scores.
            if i > 0 {
                XCTAssertLessThanOrEqual(top[i].score, top[i - 1].score, "scores must be non-increasing")
            }
            XCTAssertGreaterThanOrEqual(top[i].index, 0)
            XCTAssertLessThan(top[i].index, labelCount, "index must be a valid label index")
            XCTAssertTrue(top[i].score.isFinite, "scores must be finite")
            // BirdNET applies a sigmoid, so scores are expected in [0, 1]. A small
            // tolerance absorbs any fp16 rounding at the extremes.
            XCTAssertGreaterThanOrEqual(top[i].score, -1e-4)
            XCTAssertLessThanOrEqual(top[i].score, 1.0 + 1e-4)
        }
    }
}
