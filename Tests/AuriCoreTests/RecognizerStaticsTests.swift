import CoreML
import Foundation
import XCTest
@testable import AuriCore

final class RecognizerStaticsTests: XCTestCase {

    // MARK: - loadSpeciesLabels

    func testLoadSpeciesLabelsParsesTrimsAndFallsBackWithoutUnderscore() throws {
        let lines = [
            "Cardinalis cardinalis_Northern Cardinal",
            "  Turdus migratorius_American Robin  ",
            "",
            "NoUnderscoreLabel"
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let labels = try BirdNetCoreMLRecognizer.loadSpeciesLabels(from: url)

        // The blank line is dropped, leaving three entries.
        XCTAssertEqual(labels.count, 3)

        XCTAssertEqual(labels[0].raw, "Cardinalis cardinalis_Northern Cardinal")
        XCTAssertEqual(labels[0].scientificName, "Cardinalis cardinalis")
        XCTAssertEqual(labels[0].commonName, "Northern Cardinal")

        // Leading/trailing whitespace around the raw line is trimmed before parsing.
        XCTAssertEqual(labels[1].raw, "Turdus migratorius_American Robin")
        XCTAssertEqual(labels[1].scientificName, "Turdus migratorius")
        XCTAssertEqual(labels[1].commonName, "American Robin")

        // No underscore: scientific/common both fall back to the raw string.
        XCTAssertEqual(labels[2].raw, "NoUnderscoreLabel")
        XCTAssertEqual(labels[2].scientificName, "NoUnderscoreLabel")
        XCTAssertEqual(labels[2].commonName, "NoUnderscoreLabel")
    }

    // MARK: - stableID

    func testStableIDIsDeterministic() {
        let first = BirdNetCoreMLRecognizer.stableID(for: "Cardinalis cardinalis_Northern Cardinal")
        let second = BirdNetCoreMLRecognizer.stableID(for: "Cardinalis cardinalis_Northern Cardinal")
        XCTAssertEqual(first, second)
    }

    func testStableIDDiffersForDistinctLabels() {
        let first = BirdNetCoreMLRecognizer.stableID(for: "Cardinalis cardinalis_Northern Cardinal")
        let second = BirdNetCoreMLRecognizer.stableID(for: "Turdus migratorius_American Robin")
        XCTAssertNotEqual(first, second)
    }

    func testStableIDIsNonNegative() {
        // Parsed from the first 8 hex chars of a SHA1 digest, so it always
        // fits comfortably within a 64-bit Int and can never be negative.
        let id = BirdNetCoreMLRecognizer.stableID(for: "Some Species_Some Common Name")
        XCTAssertGreaterThanOrEqual(id, 0)
    }

    // MARK: - resample

    func testResampleSameRateReturnsIdenticalArray() {
        let samples: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(BirdNetCoreMLRecognizer.resample(samples, from: 48_000, to: 48_000), samples)
    }

    func testResampleEmptyReturnsEmpty() {
        XCTAssertEqual(BirdNetCoreMLRecognizer.resample([], from: 48_000, to: 96_000), [])
    }

    func testResampleUpsampleDoublesCount() {
        let samples = (0..<1_000).map { Float($0) }
        let output = BirdNetCoreMLRecognizer.resample(samples, from: 48_000, to: 96_000)
        XCTAssertLessThanOrEqual(abs(output.count - samples.count * 2), 1)
    }

    func testResampleDownsampleHalvesCount() {
        let samples = (0..<1_000).map { Float($0) }
        let output = BirdNetCoreMLRecognizer.resample(samples, from: 96_000, to: 48_000)
        XCTAssertLessThanOrEqual(abs(output.count - samples.count / 2), 1)
    }

    func testResampleFirstElementPreserved() {
        let samples: [Float] = [5, 6, 7, 8]
        // Upsampling is plain linear interpolation, so the first sample is copied exactly.
        let up = BirdNetCoreMLRecognizer.resample(samples, from: 48_000, to: 96_000)
        XCTAssertEqual(up.first, samples.first)

        // Downsampling now low-pass filters before decimating, so an arbitrary
        // signal's leading sample becomes a band-limited blend rather than an exact
        // copy. A constant signal has no energy to filter (unit DC gain plus edge
        // clamping), so its first sample is preserved.
        let constant = [Float](repeating: 5, count: 100)
        let down = BirdNetCoreMLRecognizer.resample(constant, from: 96_000, to: 48_000)
        XCTAssertEqual(down.first, 5, accuracy: 1e-4)
    }

    func testResampleConstantInputStaysConstant() {
        let samples = [Float](repeating: 3.0, count: 100)
        let output = BirdNetCoreMLRecognizer.resample(samples, from: 44_100, to: 48_000)
        for value in output {
            XCTAssertEqual(value, 3.0, accuracy: 1e-5)
        }
    }

    func testResampleMonotonicRampStaysWithinBounds() {
        let samples = (0..<500).map { Float($0) }
        let output = BirdNetCoreMLRecognizer.resample(samples, from: 48_000, to: 96_000)
        guard let first = samples.first, let last = samples.last else {
            return XCTFail("expected non-empty samples")
        }
        for value in output {
            XCTAssertGreaterThanOrEqual(value, first - 1e-4)
            XCTAssertLessThanOrEqual(value, last + 1e-4)
        }
    }

    // MARK: - fitWindow

    func testFitWindowExactSizeUnchanged() {
        let samples = (0..<BirdNetCoreMLRecognizer.windowSamples).map { Float($0) }
        XCTAssertEqual(BirdNetCoreMLRecognizer.fitWindow(samples), samples)
    }

    func testFitWindowLongerTruncatesToPrefix() {
        let samples = (0..<(BirdNetCoreMLRecognizer.windowSamples + 1)).map { Float($0) }
        let fitted = BirdNetCoreMLRecognizer.fitWindow(samples)
        XCTAssertEqual(fitted.count, BirdNetCoreMLRecognizer.windowSamples)
        XCTAssertEqual(fitted, Array(samples.prefix(BirdNetCoreMLRecognizer.windowSamples)))
    }

    func testFitWindowShorterZeroPadsPreservingPrefix() {
        let samples: [Float] = [1, 2, 3]
        let fitted = BirdNetCoreMLRecognizer.fitWindow(samples)
        XCTAssertEqual(fitted.count, BirdNetCoreMLRecognizer.windowSamples)
        XCTAssertEqual(Array(fitted.prefix(3)), samples)
        XCTAssertTrue(fitted.dropFirst(3).allSatisfy { $0 == 0 })
    }

    // MARK: - topPredictions

    private let sampleScores: [Float] = [0.1, 0.9, 0.3, 0.7, 0.5, 0.05, 0.8, 0.2]

    func testTopPredictionsFloat32ReturnsDescendingTopIndices() throws {
        let scores = try MLMultiArray(shape: [1, 8], dataType: .float32)
        for (index, value) in sampleScores.enumerated() {
            scores[index] = NSNumber(value: value)
        }

        let top3 = BirdNetCoreMLRecognizer.topPredictions(from: scores, limit: 3)
        XCTAssertEqual(top3.map(\.index), [1, 6, 3])
        for (result, expected) in zip(top3.map(\.score), [0.9, 0.8, 0.7]) {
            XCTAssertEqual(result, expected, accuracy: 1e-6)
        }
    }

    func testTopPredictionsFloat32LimitLargerThanCountReturnsAllSorted() throws {
        let scores = try MLMultiArray(shape: [1, 8], dataType: .float32)
        for (index, value) in sampleScores.enumerated() {
            scores[index] = NSNumber(value: value)
        }

        let all = BirdNetCoreMLRecognizer.topPredictions(from: scores, limit: 10)
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(all.map(\.index), [1, 6, 3, 4, 2, 7, 0, 5])
        XCTAssertEqual(all.map(\.score), all.map(\.score).sorted(by: >))
    }

    func testTopPredictionsDoubleFallbackPathMatchesFloat32Path() throws {
        // Exercises the non-float32 branch, which boxes each element via NSNumber.
        let scores = try MLMultiArray(shape: [1, 8], dataType: .double)
        for (index, value) in sampleScores.enumerated() {
            scores[index] = NSNumber(value: Double(value))
        }

        let top3 = BirdNetCoreMLRecognizer.topPredictions(from: scores, limit: 3)
        XCTAssertEqual(top3.map(\.index), [1, 6, 3])
        for (result, expected) in zip(top3.map(\.score), [0.9, 0.8, 0.7]) {
            XCTAssertEqual(result, expected, accuracy: 1e-6)
        }
    }

    func testTopPredictionsDoubleLimitLargerThanCountReturnsAllSorted() throws {
        let scores = try MLMultiArray(shape: [1, 8], dataType: .double)
        for (index, value) in sampleScores.enumerated() {
            scores[index] = NSNumber(value: Double(value))
        }

        let all = BirdNetCoreMLRecognizer.topPredictions(from: scores, limit: 10)
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(all.map(\.index), [1, 6, 3, 4, 2, 7, 0, 5])
    }

    // MARK: - makeInputProvider

    func testMakeInputProviderWithExactWindowSizeReturnsMultiArrayFeature() throws {
        let featureName = "input"
        var samples = [Float](repeating: 0, count: BirdNetCoreMLRecognizer.windowSamples)
        samples[0] = 1.23

        let provider = try BirdNetCoreMLRecognizer.makeInputProvider(samples: samples, featureName: featureName)
        let value = provider.featureValue(for: featureName)
        XCTAssertNotNil(value)

        let multiArray = try XCTUnwrap(value?.multiArrayValue)
        XCTAssertEqual(multiArray.count, BirdNetCoreMLRecognizer.windowSamples)
        XCTAssertEqual(multiArray[0].floatValue, 1.23, accuracy: 1e-5)
    }

    func testMakeInputProviderWithFewerSamplesThanWindowThrows() {
        let featureName = "input"
        let shortSamples = [Float](repeating: 0, count: BirdNetCoreMLRecognizer.windowSamples - 1)

        XCTAssertThrowsError(
            try BirdNetCoreMLRecognizer.makeInputProvider(samples: shortSamples, featureName: featureName)
        )
    }
}
