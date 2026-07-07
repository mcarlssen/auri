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

// MARK: - Spectral NR helpers

/// Coherent single-frequency power over the whole buffer (a one-bin DFT). A pure
/// linear delay only adds a constant phase, so this magnitude is delay-invariant —
/// letting us compare the STFT's `n`-sample-latency output against its input.
private func binPower(_ x: [Float], freq: Float, sampleRate: Float) -> Double {
    var re = 0.0
    var im = 0.0
    let w = 2.0 * Double.pi * Double(freq) / Double(sampleRate)
    for n in 0..<x.count {
        let a = w * Double(n)
        re += Double(x[n]) * cos(a)
        im -= Double(x[n]) * sin(a)
    }
    return re * re + im * im
}

private func mixedTone(count: Int, sampleRate: Float) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    let parts: [(Float, Float)] = [(440, 0.25), (1_000, 0.2), (3_000, 0.15), (7_000, 0.1)]
    for (freq, amp) in parts {
        for i in 0..<count {
            out[i] += amp * sinf(2 * .pi * freq * Float(i) / sampleRate)
        }
    }
    return out
}

private func whiteNoise(count: Int, amplitude: Float, seed: UInt64) -> [Float] {
    var generator = SeededGenerator(seed: seed)
    return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
}

// MARK: - STFTProcessor (Step 1: perfect-reconstruction WOLA core)

final class STFTProcessorTests: XCTestCase {

    /// THE foundational gate: a unity (nil) gain mask must reproduce the input
    /// exactly, up to Float FFT round-trip error, over the steady-state region.
    /// If this fails, every spectral result downstream is meaningless. The output
    /// trails the input by exactly `n` samples (fixed latency); compare shifted.
    func testStftIdentityReconstruction() {
        let sr: Float = 48_000
        let m = 8_192
        let processor = STFTProcessor()
        let n = processor.n
        let input = mixedTone(count: m, sampleRate: sr)
        let output = processor.process(input)

        XCTAssertEqual(output.count, m)
        // Steady, fully-overlapped, fully-finalized interior (exclude the first/last
        // partial-overlap frames). output[n + r] reconstructs input[r].
        for r in (n)..<(m - 2 * n) {
            XCTAssertEqual(output[n + r], input[r], accuracy: 1e-4)
        }
    }

    /// An explicit all-ones gain mask (exercising the magnitude + gain-apply path)
    /// must also be bit-faithful — proving the gain hook itself is transparent.
    func testStftUnityGainMaskReproducesInput() {
        let sr: Float = 48_000
        let m = 8_192
        let processor = STFTProcessor()
        let n = processor.n
        let input = mixedTone(count: m, sampleRate: sr)
        let output = processor.process(input) { mags in
            [Float](repeating: 1, count: mags.count)
        }
        XCTAssertEqual(output.count, m)
        for r in (n)..<(m - 2 * n) {
            XCTAssertEqual(output[n + r], input[r], accuracy: 1e-4)
        }
    }

    /// Each streaming call returns exactly as many samples as it was handed, and
    /// the totals match across arbitrarily chunked calls plus the final tail.
    func testStftOutputLengthMatchesInputAcrossChunks() {
        let processor = STFTProcessor()
        let input = mixedTone(count: 9_000, sampleRate: 48_000)
        let chunkSizes = [1, 256, 1_024, 333, 2_000, 77, 4_096]
        var produced = 0
        var idx = 0
        var ci = 0
        while idx < input.count {
            let k = min(chunkSizes[ci % chunkSizes.count], input.count - idx)
            let out = processor.process(Array(input[idx..<idx + k]))
            XCTAssertEqual(out.count, k) // per-call length invariant
            produced += out.count
            idx += k
            ci += 1
        }
        XCTAssertEqual(produced, input.count)
    }

    /// Chunk boundaries must not affect the samples produced: frames are taken at
    /// the same absolute positions regardless of how input is grouped.
    func testStftStreamingMatchesSingleCall() {
        let input = mixedTone(count: 8_000, sampleRate: 48_000)

        let single = STFTProcessor().process(input)

        let streamed = STFTProcessor()
        var out: [Float] = []
        let chunkSizes = [137, 1_024, 500, 2_048, 63, 1_000]
        var idx = 0
        var ci = 0
        while idx < input.count {
            let k = min(chunkSizes[ci % chunkSizes.count], input.count - idx)
            out += streamed.process(Array(input[idx..<idx + k]))
            idx += k
            ci += 1
        }

        XCTAssertEqual(single.count, out.count)
        for i in single.indices {
            XCTAssertEqual(single[i], out[i], accuracy: 1e-5)
        }
    }
}

// MARK: - SpectralNoiseReducer (Steps 2 & 3: profile learning + subtraction)

final class SpectralNoiseReducerTests: XCTestCase {

    private let sr: Float = 48_000

    private func bin(_ freq: Float, n: Int) -> Int {
        Int((freq * Float(n) / sr).rounded())
    }

    /// Step 2: a steady broadband noise floor is learned, but an intermittent
    /// loud 3 kHz tone (transient + energetic) never lifts the profile at 3 kHz.
    func testProfileLearnsNoiseNotTone() {
        let total = 96_000 // 2 s
        var signal = whiteNoise(count: total, amplitude: 0.05, seed: 7)
        // Tone OFF for the opening stretch so the profile seeds on clean noise,
        // then bursts on intermittently — loud and transient, so it is rejected.
        let toneFreq: Float = 3_000
        for i in 0..<total where (i % 8_192) >= 4_096 && (i % 8_192) < 6_144 {
            signal[i] += 0.5 * sinf(2 * .pi * toneFreq * Float(i) / sr)
        }

        let reducer = SpectralNoiseReducer()
        var buffer = signal
        reducer.process(&buffer)

        XCTAssertTrue(reducer.hasNoiseProfile)
        let profile = reducer.noiseProfile
        let toneBin = bin(toneFreq, n: profile.count) // 64

        var sum: Float = 0
        var count = 0
        for k in 20..<200 where abs(k - toneBin) > 4 {
            sum += profile[k]
            count += 1
        }
        let avgNoise = sum / Float(count)
        XCTAssertGreaterThan(avgNoise, 0) // the steady noise floor WAS learned
        // No spike at 3 kHz: had the tone leaked, this bin would be many times the
        // flat noise level (the tone is ~10× the noise amplitude).
        XCTAssertLessThan(profile[toneBin], 3 * avgNoise)
    }

    /// Step 2: a continuously (fast-)swept tone is non-stationary every frame, so
    /// no frame is ever accepted — the profile is never even established.
    func testSweptToneRejectedFromProfile() {
        let total = 96_000
        var signal = [Float](repeating: 0, count: total)
        // Sweep 2 kHz→10 kHz over 0.25 s, repeating — several bins of motion per
        // hop, far faster than any steady machine tone.
        let sweepSamples = 12_000
        for i in 0..<total {
            let p = Float(i % sweepSamples) / Float(sweepSamples)
            let freq = 2_000 + 8_000 * p
            signal[i] = 0.4 * sinf(2 * .pi * freq * Float(i) / sr)
        }

        let reducer = SpectralNoiseReducer()
        var buffer = signal
        reducer.process(&buffer)

        XCTAssertFalse(reducer.hasNoiseProfile)
        XCTAssertEqual(reducer.noiseProfile.max() ?? 0, 0)
    }

    /// Step 3: steady white noise is measurably attenuated once the profile has
    /// converged (measure the late, steady tail; skip the latency/convergence head).
    func testSpectralSubtractionReducesWhiteNoise() {
        let total = 96_000
        let signal = whiteNoise(count: total, amplitude: 0.1, seed: 11)
        let inputRMS = rms(signal)

        let reducer = SpectralNoiseReducer()
        var buffer = signal
        reducer.process(&buffer)

        let tail = Array(buffer.suffix(20_000))
        XCTAssertLessThan(rms(tail), 0.6 * inputRMS)
        for v in buffer { XCTAssertTrue(v.isFinite) }
    }

    /// Step 3: against a learned noise floor, a strong transient 3 kHz burst train
    /// (bird-like: short on, long off) survives, and its SNR improves vs the input.
    func testStrongToneSurvivesAndSNRImproves() {
        let total = 96_000
        var signal = whiteNoise(count: total, amplitude: 0.05, seed: 13)
        let toneFreq: Float = 3_000
        let refFreq: Float = 9_000 // noise-only reference band
        for i in 0..<total where (i % 8_192) >= 4_096 && (i % 8_192) < 5_120 {
            signal[i] += 0.6 * sinf(2 * .pi * toneFreq * Float(i) / sr)
        }

        let pToneIn = binPower(signal, freq: toneFreq, sampleRate: sr)
        let pRefIn = binPower(signal, freq: refFreq, sampleRate: sr)

        let reducer = SpectralNoiseReducer()
        var buffer = signal
        reducer.process(&buffer)

        let pToneOut = binPower(buffer, freq: toneFreq, sampleRate: sr)
        let pRefOut = binPower(buffer, freq: refFreq, sampleRate: sr)

        // The tone survives with most of its energy intact...
        XCTAssertGreaterThan(pToneOut, 0.3 * pToneIn)
        // ...and its signal-to-noise ratio improves, because the noise reference
        // band is attenuated far more than the tone.
        let snrIn = pToneIn / max(pRefIn, 1e-12)
        let snrOut = pToneOut / max(pRefOut, 1e-12)
        XCTAssertGreaterThan(snrOut, 2 * snrIn)
    }

    /// Step 3: silence in → silence out, with no NaNs/Infs from any divide.
    func testSilenceStaysSilentAndFinite() {
        let reducer = SpectralNoiseReducer()
        var buffer = [Float](repeating: 0, count: 8_192)
        reducer.process(&buffer)
        XCTAssertEqual(buffer.count, 8_192)
        for v in buffer { XCTAssertTrue(v.isFinite) }
        XCTAssertLessThan(rms(buffer), 1e-6)
    }

    /// Step 3: fully deterministic — identical seeded input yields identical output.
    func testSpectralSubtractionIsDeterministic() {
        let signal = whiteNoise(count: 40_000, amplitude: 0.1, seed: 17)

        let a = SpectralNoiseReducer()
        var bufferA = signal
        a.process(&bufferA)

        let b = SpectralNoiseReducer()
        var bufferB = signal
        b.process(&bufferB)

        XCTAssertEqual(bufferA, bufferB)
    }
}
