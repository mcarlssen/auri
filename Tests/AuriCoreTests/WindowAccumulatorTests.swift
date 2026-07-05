import XCTest
@testable import AuriCore

/// Builds mono float32 PCM `Data`, mirroring how real audio bytes are packed.
private func floatsData(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

/// Reinterprets `Data` produced by `WindowAccumulator` back into `[Float]` for
/// assertions. Windows returned by `nextWindow()` are always fresh, tightly
/// packed `Data` copies, so this is safe.
private func floats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float.self))
    }
}

final class WindowAccumulatorTests: XCTestCase {

    func testNextWindowNilWhenInsufficientDataBuffered() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 8)
        accumulator.append(floatsData([1, 2, 3]))
        XCTAssertNil(accumulator.nextWindow())
    }

    func testExactWindowThenHopAdvancesByHopByteCount() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 8) // hop = 2 samples
        accumulator.append(floatsData([1, 2, 3, 4]))
        XCTAssertEqual(floats(accumulator.nextWindow()!), [1, 2, 3, 4])

        accumulator.append(floatsData([5, 6]))
        XCTAssertEqual(floats(accumulator.nextWindow()!), [3, 4, 5, 6])
    }

    func testMultipleWindowsDrainedFromOneBigAppend() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 8) // hop = 2 samples
        accumulator.append(floatsData([1, 2, 3, 4, 5, 6, 7, 8]))

        XCTAssertEqual(floats(accumulator.nextWindow()!), [1, 2, 3, 4])
        XCTAssertEqual(floats(accumulator.nextWindow()!), [3, 4, 5, 6])
        XCTAssertEqual(floats(accumulator.nextWindow()!), [5, 6, 7, 8])
        XCTAssertNil(accumulator.nextWindow())
    }

    func testStrayTrailingByteIsTrimmedAndDoesNotBreakFloatAlignment() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 16)
        accumulator.append(floatsData([1, 2, 3])) // 12 bytes
        accumulator.append(Data([0x00])) // 1 stray byte; buffer count (13) is trimmed back to 12
        accumulator.append(floatsData([9])) // 4 more bytes, buffer now exactly 16 bytes

        // If the stray byte had not been trimmed, this would decode garbage
        // instead of the clean float sequence below.
        XCTAssertEqual(floats(accumulator.nextWindow()!), [1, 2, 3, 9])
    }

    func testSilenceGateSkipsQuietWindowAndReturnsLoudOne() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 16) // hop = 4 samples
        accumulator.silenceGateEnabled = true
        accumulator.silenceGateThresholdLinear = 0.5

        accumulator.append(floatsData([0.1, 0.1, 0.1, 0.1])) // quiet, RMS below threshold
        accumulator.append(floatsData([0.6, 0.6, 0.6, 0.6])) // loud, RMS above threshold

        let window = accumulator.nextWindow()
        XCTAssertEqual(floats(window!), [0.6, 0.6, 0.6, 0.6])
        XCTAssertEqual(accumulator.silentWindowsSkipped, 1)
    }

    func testSilenceGateUsesRMSSoSustainedNegativeEnergyAlsoPasses() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 16)
        accumulator.silenceGateEnabled = true
        accumulator.silenceGateThresholdLinear = 0.5

        accumulator.append(floatsData([0.1, 0.1, 0.1, 0.1])) // quiet
        accumulator.append(floatsData([-0.6, -0.6, -0.6, -0.6])) // loud, RMS is sign-agnostic

        let window = accumulator.nextWindow()
        XCTAssertEqual(floats(window!), [-0.6, -0.6, -0.6, -0.6])
        XCTAssertEqual(accumulator.silentWindowsSkipped, 1)
    }

    func testSilenceGateDisabledReturnsQuietWindowAndCounterStaysZero() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 16)
        accumulator.append(floatsData([0.1, 0.1, 0.1, 0.1]))

        let window = accumulator.nextWindow()
        XCTAssertEqual(floats(window!), [0.1, 0.1, 0.1, 0.1])
        XCTAssertEqual(accumulator.silentWindowsSkipped, 0)
    }

    func testResetSilentCountZeroesCounter() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 16)
        accumulator.silenceGateEnabled = true
        accumulator.silenceGateThresholdLinear = 0.5
        accumulator.append(floatsData([0.1, 0.1, 0.1, 0.1]))
        accumulator.append(floatsData([0.6, 0.6, 0.6, 0.6]))
        _ = accumulator.nextWindow()
        XCTAssertEqual(accumulator.silentWindowsSkipped, 1)

        accumulator.resetSilentCount()
        XCTAssertEqual(accumulator.silentWindowsSkipped, 0)
    }

    func testResetEmptiesBuffer() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 8)
        accumulator.append(floatsData([1, 2, 3, 4]))
        accumulator.reset(keepingCapacity: false)
        XCTAssertNil(accumulator.nextWindow())
    }

    func testHopByteCountMutationMidStreamIsHonoredOnNextDrain() {
        var accumulator = WindowAccumulator(windowSampleCount: 4, hopByteCount: 16) // hop = full window
        accumulator.append(floatsData([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(floats(accumulator.nextWindow()!), [1, 2, 3, 4])
        // Buffer now holds [5, 6, 7, 8] (4 samples / 16 bytes).

        accumulator.hopByteCount = 8 // shrink hop to 2 samples before the next drain
        accumulator.append(floatsData([9, 10]))
        // With the old hop (16 bytes) this second window would exhaust the
        // buffer; with the new smaller hop, 2 samples remain for a third window.
        XCTAssertEqual(floats(accumulator.nextWindow()!), [5, 6, 7, 8])
        XCTAssertEqual(floats(accumulator.nextWindow()!), [7, 8, 9, 10])
        XCTAssertNil(accumulator.nextWindow())
    }
}
