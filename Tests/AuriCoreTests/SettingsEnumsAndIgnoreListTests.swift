import XCTest
@testable import AuriCore

final class DetectionOverlapTests: XCTestCase {
    func testHopSamplesForStandardWindow() {
        XCTAssertEqual(DetectionOverlap.off.hopSamples(windowSamples: 144_000), 144_000)
        XCTAssertEqual(DetectionOverlap.half.hopSamples(windowSamples: 144_000), 72_000)
        XCTAssertEqual(DetectionOverlap.twoThirds.hopSamples(windowSamples: 144_000), 48_000)
        XCTAssertEqual(DetectionOverlap.threeQuarters.hopSamples(windowSamples: 144_000), 36_000)
    }

    func testHopSamplesNeverGoesBelowOne() {
        for overlap in DetectionOverlap.allCases {
            XCTAssertGreaterThanOrEqual(overlap.hopSamples(windowSamples: 1), 1)
        }
    }
}

final class SpectrogramOverlapTests: XCTestCase {
    func testHopSizeForStandardFFT() {
        XCTAssertEqual(SpectrogramOverlap.half.hopSize(fftSize: 1024), 512)
        XCTAssertEqual(SpectrogramOverlap.threeQuarters.hopSize(fftSize: 1024), 256)
        XCTAssertEqual(SpectrogramOverlap.sevenEighths.hopSize(fftSize: 1024), 128)
    }

    func testHopSizeNeverGoesBelowOne() {
        for overlap in SpectrogramOverlap.allCases {
            XCTAssertGreaterThanOrEqual(overlap.hopSize(fftSize: 1), 1)
        }
    }
}

final class SpectrogramFrequencyScaleTests: XCTestCase {
    private let minHz: Float = 100
    private let maxHz: Float = 15_000

    func testPositionFrequencyRoundTrip() {
        let fractions: [Float] = [0, 0.25, 0.5, 0.75, 1.0]
        for scale in SpectrogramFrequencyScale.allCases {
            for fraction in fractions {
                let frequency = scale.frequency(atPosition: fraction, minHz: minHz, maxHz: maxHz)
                let roundTripped = scale.displayPosition(for: frequency, minHz: minHz, maxHz: maxHz)
                XCTAssertEqual(
                    roundTripped, fraction, accuracy: 1e-3,
                    "Round trip failed for \(scale) at fraction \(fraction)"
                )
            }
        }
    }

    func testDisplayPositionEndpoints() {
        for scale in SpectrogramFrequencyScale.allCases {
            let minPosition = scale.displayPosition(for: minHz, minHz: minHz, maxHz: maxHz)
            let maxPosition = scale.displayPosition(for: maxHz, minHz: minHz, maxHz: maxHz)
            XCTAssertEqual(minPosition, 0, accuracy: 1e-3, "minHz should map near 0 for \(scale)")
            XCTAssertEqual(maxPosition, 1, accuracy: 1e-3, "maxHz should map near 1 for \(scale)")
        }
    }
}

final class RawValueStabilityTests: XCTestCase {
    // These enums persist their raw value in UserDefaults. Renaming a case
    // (and thus its raw value) silently discards existing user settings, so
    // pin the exact strings here.

    func testDetectionOverlapRawValues() {
        XCTAssertEqual(DetectionOverlap.off.rawValue, "off")
        XCTAssertEqual(DetectionOverlap.half.rawValue, "half")
        XCTAssertEqual(DetectionOverlap.twoThirds.rawValue, "twoThirds")
        XCTAssertEqual(DetectionOverlap.threeQuarters.rawValue, "threeQuarters")
    }

    func testSpectrogramFrequencyScaleRawValues() {
        XCTAssertEqual(SpectrogramFrequencyScale.mel.rawValue, "mel")
        XCTAssertEqual(SpectrogramFrequencyScale.linear.rawValue, "linear")
        XCTAssertEqual(SpectrogramFrequencyScale.logarithmic.rawValue, "logarithmic")
    }

    func testAudioInputSourceRawValues() {
        XCTAssertEqual(AudioInputSource.defaultMic.rawValue, "defaultMic")
        XCTAssertEqual(AudioInputSource.blackhole.rawValue, "blackhole")
        XCTAssertEqual(AudioInputSource.selectedDevice.rawValue, "selectedDevice")
    }
}

final class IgnoreListTests: XCTestCase {
    func testMatchesById() {
        let ignoreList = IgnoreList(speciesIDs: [1, 2], speciesNames: ["Robin"])
        XCTAssertTrue(ignoreList.isSpeciesIgnored(birdId: 1, birdName: "Sparrow"))
    }

    func testMatchesByName() {
        let ignoreList = IgnoreList(speciesIDs: [1, 2], speciesNames: ["Robin"])
        XCTAssertTrue(ignoreList.isSpeciesIgnored(birdId: 99, birdName: "Robin"))
    }

    func testNoMatchReturnsFalse() {
        let ignoreList = IgnoreList(speciesIDs: [1, 2], speciesNames: ["Robin"])
        XCTAssertFalse(ignoreList.isSpeciesIgnored(birdId: 99, birdName: "Sparrow"))
    }

    func testNameMatchingIsCaseSensitive() {
        // Pinning current behavior: matching uses plain Set membership, which
        // is case-sensitive, so a differently-cased name is not considered ignored.
        let ignoreList = IgnoreList(speciesIDs: [], speciesNames: ["Robin"])
        XCTAssertFalse(ignoreList.isSpeciesIgnored(birdId: 99, birdName: "robin"))
    }

    func testEmptyIgnoreListMatchesNothing() {
        let ignoreList = IgnoreList(speciesIDs: [], speciesNames: [])
        XCTAssertFalse(ignoreList.isSpeciesIgnored(birdId: 1, birdName: "Robin"))
    }
}
