import Accelerate
import XCTest
@testable import AuriCore

/// Deterministic pseudo-random generator so noise-driven tests never depend on
/// an unseeded system RNG.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func rms(_ x: [Float]) -> Float {
    guard !x.isEmpty else { return 0 }
    let sum = x.reduce(0.0) { $0 + Double($1) * Double($1) }
    return Float((sum / Double(x.count)).squareRoot())
}

private func sineTone(freq: Float, count: Int, sampleRate: Float, amplitude: Float = 1) -> [Float] {
    (0..<count).map { amplitude * sinf(2 * .pi * freq * Float($0) / sampleRate) }
}

// MARK: - BiquadHighPass

final class BiquadHighPassTests: XCTestCase {

    func testRemovesDCAfterSettling() {
        var filter = BiquadHighPass(cutoffHz: 300, sampleRate: 48_000)
        var samples = [Float](repeating: 0.7, count: 4096)
        filter.process(&samples)
        // A high-pass has zero gain at DC, so a constant input settles to ~0.
        let tail = Array(samples.suffix(512))
        XCTAssertLessThan(rms(tail), 0.005)
    }

    func testAttenuatesLowToneAndPassesHighTone() {
        let sr: Float = 48_000

        var lowFilter = BiquadHighPass(cutoffHz: 300, sampleRate: Double(sr))
        var low = sineTone(freq: 100, count: 9600, sampleRate: sr)
        lowFilter.process(&low)
        let lowRMS = rms(Array(low.suffix(4800)))

        var highFilter = BiquadHighPass(cutoffHz: 300, sampleRate: Double(sr))
        var high = sineTone(freq: 4000, count: 9600, sampleRate: sr)
        highFilter.process(&high)
        let highRMS = rms(Array(high.suffix(4800)))

        // 100 Hz sits well below the 300 Hz corner of a 4th-order high-pass, so it
        // is heavily attenuated; 4 kHz passes with its ~0.707 RMS preserved.
        XCTAssertLessThan(lowRMS, 0.1)
        XCTAssertGreaterThan(highRMS, 0.65)
        XCTAssertEqual(highRMS, 0.707, accuracy: 0.05)
        XCTAssertLessThan(lowRMS, highRMS)
    }

    func testStateContinuityAcrossChunksMatchesSingleCall() {
        let full = sineTone(freq: 1000, count: 2000, sampleRate: 48_000)

        var oneShotFilter = BiquadHighPass(cutoffHz: 300, sampleRate: 48_000)
        var oneShot = full
        oneShotFilter.process(&oneShot)

        var chunkedFilter = BiquadHighPass(cutoffHz: 300, sampleRate: 48_000)
        var a = Array(full[0..<777])
        var b = Array(full[777..<2000])
        chunkedFilter.process(&a)
        chunkedFilter.process(&b)
        let chunked = a + b

        XCTAssertEqual(chunked.count, oneShot.count)
        for i in oneShot.indices {
            // Persistent per-section state means the split matches the whole:
            // no discontinuity at the buffer seam.
            XCTAssertEqual(chunked[i], oneShot[i], accuracy: 1e-5)
        }
    }

    func testImpulseResponseStaysFiniteAndBounded() {
        var filter = BiquadHighPass(cutoffHz: 300, sampleRate: 48_000)
        var impulse = [Float](repeating: 0, count: 4096)
        impulse[0] = 1
        filter.process(&impulse)
        for v in impulse {
            XCTAssertTrue(v.isFinite)
            XCTAssertLessThanOrEqual(abs(v), 4)
        }
    }

    func testDegenerateCutoffProducesFiniteOutput() {
        // Cutoffs at/above Nyquist or at/below 0 must be clamped, not blow up.
        for cutoff in [0.0, -50.0, 24_000.0, 48_000.0] {
            var filter = BiquadHighPass(cutoffHz: cutoff, sampleRate: 48_000)
            var samples = sineTone(freq: 1000, count: 1024, sampleRate: 48_000)
            filter.process(&samples)
            for v in samples { XCTAssertTrue(v.isFinite) }
        }
    }
}

// MARK: - NoiseReducer

final class NoiseReducerTests: XCTestCase {

    func testDisabledIsBitIdentity() {
        var reducer = NoiseReducer()
        reducer.configure(enabled: false, cutoffHz: 300, sampleRate: 16_000)
        var generator = SeededGenerator(seed: 5)
        let input = (0..<5000).map { _ in Float.random(in: -1...1, using: &generator) }
        var output = input
        reducer.process(&output)
        // The off path is a strict no-op.
        XCTAssertEqual(output, input)
    }

    func testEnabledHighPassPreservesLength() {
        var generator = SeededGenerator(seed: 6)
        let input = (0..<5000).map { _ in Float.random(in: -0.5...0.5, using: &generator) }

        var reducer = NoiseReducer()
        reducer.configure(enabled: true, cutoffHz: 300, sampleRate: 16_000)
        var output = input
        reducer.process(&output)
        XCTAssertEqual(output.count, input.count)
        XCTAssertNotEqual(output, input) // the high-pass changed the signal
        for v in output { XCTAssertTrue(v.isFinite) }
    }

    func testReconfigureToDisabledRestoresNoOp() {
        var reducer = NoiseReducer()
        reducer.configure(enabled: true, cutoffHz: 500, sampleRate: 16_000)
        var warmup = sineTone(freq: 1000, count: 2048, sampleRate: 16_000)
        reducer.process(&warmup)

        reducer.configure(enabled: false, cutoffHz: 500, sampleRate: 16_000)
        var generator = SeededGenerator(seed: 8)
        let input = (0..<3000).map { _ in Float.random(in: -1...1, using: &generator) }
        var output = input
        reducer.process(&output)
        XCTAssertEqual(output, input)
    }
}
