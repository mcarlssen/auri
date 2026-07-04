import XCTest
@testable import AuriCore

/// Pure-static coverage for `AudioFileLoader`. `loadSamples(from:)` needs an
/// actual audio file on disk and is intentionally not covered here.
final class AudioFileLoaderTests: XCTestCase {

    // MARK: - windows(from:hopSamples:)

    func testWindowsEmptyInputReturnsNoWindows() {
        XCTAssertEqual(AudioFileLoader.windows(from: []), [])
    }

    func testWindowsFewerThanWindowSamplesZeroPadsWithPrefixIntact() {
        let samples: [Float] = [1, 2, 3]
        let result = AudioFileLoader.windows(from: samples)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].count, AudioFileLoader.windowSamples)
        XCTAssertEqual(Array(result[0].prefix(3)), samples)
        XCTAssertTrue(result[0].dropFirst(3).allSatisfy { $0 == 0 })
    }

    func testWindowsExactWindowSizeReturnsSingleUnpaddedWindow() {
        let samples = (0..<AudioFileLoader.windowSamples).map { Float($0) }
        let result = AudioFileLoader.windows(from: samples)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], samples)
    }

    func testWindowsOneExtraSampleWithFullHopProducesTwoWindowsSecondZeroPadded() {
        let count = AudioFileLoader.windowSamples + 1
        let samples = (0..<count).map { Float($0) }
        let result = AudioFileLoader.windows(from: samples, hopSamples: AudioFileLoader.windowSamples)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], Array(samples.prefix(AudioFileLoader.windowSamples)))
        XCTAssertEqual(result[1].count, AudioFileLoader.windowSamples)
        XCTAssertEqual(result[1].first, samples[AudioFileLoader.windowSamples])
        XCTAssertTrue(result[1].dropFirst(1).allSatisfy { $0 == 0 })
    }

    func testWindowsOverlapWithHalfHopProducesThreeWindows() {
        let count = AudioFileLoader.windowSamples * 2
        let samples = (0..<count).map { Float($0) }
        let hop = AudioFileLoader.windowSamples / 2

        let result = AudioFileLoader.windows(from: samples, hopSamples: hop)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1].first, samples[72_000])
    }

    // MARK: - offsetSeconds(forWindowIndex:hopSamples:)

    func testOffsetSecondsComputesFromIndexTimesHopOverSampleRate() {
        XCTAssertEqual(
            AudioFileLoader.offsetSeconds(forWindowIndex: 3, hopSamples: 72_000),
            4.5,
            accuracy: 1e-9
        )
    }

    // MARK: - pcmData(from:)

    func testPCMDataRoundTripsThroughRawBytes() {
        let samples: [Float] = [1.5, -2.25, 3.75, 0, -100.0]
        let data = AudioFileLoader.pcmData(from: samples)

        XCTAssertEqual(data.count, samples.count * MemoryLayout<Float>.size)

        let roundTripped = data.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self))
        }
        XCTAssertEqual(roundTripped, samples)
    }
}
