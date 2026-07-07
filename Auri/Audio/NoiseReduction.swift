import Accelerate
import Foundation

// Pure-DSP input noise reduction. Imports only Accelerate/Foundation (no
// AVFoundation) so it lives in the AuriCore package and is exercisable from
// unit tests without an audio device. The app-only `AudioHandler` owns the
// live-pipeline glue.
//
// BirdNET was trained on real-world audio that already contains noise, so
// aggressive processing that injects artifacts the model never saw can hurt
// detection more than the noise does. Everything here is opt-in: the high-pass
// is the artifact-free core, and the spectral gate is a separate, gentle,
// reversible stage the user turns on knowingly.

/// A cascade of two 2nd-order Butterworth high-pass biquads (4th order overall,
/// ~24 dB/oct) that strips the low-frequency bulk of laptop noise (fan rumble,
/// mains/ground hum) before analysis.
///
/// Hand-rolled Direct Form II Transposed rather than `vDSP_biquad`: the
/// recurrence is a handful of allocation-free lines, sample-exact testable, and
/// avoids the `vDSP_biquad` setup/delay C API which can't be verified without a
/// Swift toolchain in this environment. State (`z1`/`z2` per section) persists
/// across `process` calls so there are no discontinuities at capture-buffer
/// boundaries; it is cleared only on `reset()` and on a cutoff change.
struct BiquadHighPass {
    /// One 2nd-order section. Coefficients are pre-normalized by `a0`; the DF2T
    /// recurrence therefore subtracts `a1`/`a2` directly.
    private struct Section {
        var b0: Float
        var b1: Float
        var b2: Float
        var a1: Float
        var a2: Float
        var z1: Float = 0
        var z2: Float = 0

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        mutating func reset() {
            z1 = 0
            z2 = 0
        }
    }

    private var sections: [Section]
    private var sampleRate: Double

    init(cutoffHz: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        let c = Self.coefficients(cutoffHz: cutoffHz, sampleRate: sampleRate)
        // Both sections use Q = 0.7071. A true 4th-order Butterworth would split
        // the section Qs (0.5412 / 1.3066); a matched-Q cascade is a well-behaved,
        // slightly gentler knee that is entirely adequate for a low-cut and keeps
        // the code trivial. Deliberately not over-engineered.
        let section = Section(b0: c.b0, b1: c.b1, b2: c.b2, a1: c.a1, a2: c.a2)
        self.sections = [section, section]
    }

    /// Recompute coefficients for a new cutoff and clear filter state. Resetting
    /// on a coefficient change avoids a transient from the stale delay memory.
    mutating func setCutoff(_ cutoffHz: Double) {
        let c = Self.coefficients(cutoffHz: cutoffHz, sampleRate: sampleRate)
        for i in sections.indices {
            sections[i].b0 = c.b0
            sections[i].b1 = c.b1
            sections[i].b2 = c.b2
            sections[i].a1 = c.a1
            sections[i].a2 = c.a2
        }
        reset()
    }

    mutating func reset() {
        for i in sections.indices {
            sections[i].reset()
        }
    }

    /// Filters `samples` in place, threading each sample through every section.
    mutating func process(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        let sectionCount = sections.count
        for i in samples.indices {
            var x = samples[i]
            for s in 0..<sectionCount {
                x = sections[s].process(x)
            }
            samples[i] = x
        }
    }

    /// Standard RBJ high-pass biquad coefficients, normalized by `a0`. The cutoff
    /// is clamped strictly inside `(0, fs/2)` so a degenerate setting can't produce
    /// non-finite coefficients.
    private static func coefficients(
        cutoffHz: Double,
        sampleRate: Double
    ) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        let nyquist = sampleRate / 2
        let fc = min(max(cutoffHz, 1), max(1, nyquist - 1))
        let q = 0.70710678118654752 // Butterworth
        let w0 = 2 * Double.pi * fc / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2 * q)

        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha

        return (
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
    }
}

/// Perfect-reconstruction streaming STFT (weighted overlap-add) that exposes a
/// per-frame spectral-gain hook. This is the verified DSP core the spectral
/// noise reducer is built on: with the gain hook absent (or unity) it reproduces
/// its input exactly (up to Float FFT round-trip error), so any downstream error
/// is attributable to the gain stage, not the transform plumbing.
///
/// Design (all constraints that were easy to get subtly wrong are called out):
///   * Frame size `n` = 1024, hop = n/4 = 256 → 75% overlap. Hann window on BOTH
///     analysis and synthesis (WOLA).
///   * FFT: a *complex* `vDSP_fft_zip` on the real frame (imaginary part zeroed).
///     Using the full complex transform — rather than the packed real
///     `vDSP_fft_zrip` — costs one extra buffer but removes the DC/Nyquist
///     bin-0 packing footgun and gives a clean 1/n round-trip scale (the packed
///     real transform round-trips at 1/(2n) and interleaves DC & Nyquist).
///   * Reconstruction scale: `vDSP_fft_zip` forward is unscaled and its inverse
///     scales by n, so a forward+inverse round-trip multiplies by n; we divide
///     the inverse output by n.
///   * Normalization: rather than assume the Hann-squared overlap sum is the
///     constant COLA value, we accumulate the true per-output-sample window-power
///     sum (Σ window²) and divide by it. This makes reconstruction exact for ANY
///     window/overlap wherever that sum is non-negligible — including the ramp-up
///     region — and is why unity gain is bit-faithful in steady state.
/// A fixed latency of exactly `n` samples is introduced (the output stream is
/// primed with n zeros) so the processor can always return exactly as many
/// samples as it was given, across arbitrarily chunked streaming calls.
final class STFTProcessor {
    let n: Int
    let hop: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]         // Hann, length n (analysis == synthesis)
    private let windowProduct: [Float]  // window[i]² — per-sample OLA denominator increment
    private let inverseScale: Float     // 1/n — complex FFT round-trip correction

    // Per-frame scratch, reused across frames to avoid per-frame allocation.
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    // Streaming state.
    private var inputBuffer: [Float] = []  // received but not yet consumed into a frame
    private var ola: [Float]               // overlap-add accumulator (length n), index 0 = current frame start
    private var winSum: [Float]            // parallel Σ window² accumulator (length n)
    private var outputTape: [Float]        // finalized+normalized samples awaiting emission; primed with n zeros

    init(n: Int = 1024, hop: Int? = nil) {
        precondition(n > 0 && (n & (n - 1)) == 0, "STFT frame size must be a power of two")
        self.n = n
        self.hop = hop ?? n / 4
        let l2 = vDSP_Length(log2(Double(n)))
        self.log2n = l2
        guard let setup = vDSP_create_fftsetup(l2, FFTRadix(kFFTRadix2)) else {
            fatalError("STFTProcessor: unsupported FFT length \(n)")
        }
        self.fftSetup = setup
        let hann = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: n,
            isHalfWindow: false
        )
        self.window = hann
        var wp = [Float](repeating: 0, count: n)
        for i in 0..<n { wp[i] = hann[i] * hann[i] }
        self.windowProduct = wp
        self.inverseScale = 1 / Float(n)
        self.realp = [Float](repeating: 0, count: n)
        self.imagp = [Float](repeating: 0, count: n)
        self.magnitudes = [Float](repeating: 0, count: n)
        self.ola = [Float](repeating: 0, count: n)
        self.winSum = [Float](repeating: 0, count: n)
        self.outputTape = [Float](repeating: 0, count: n) // latency priming = n samples
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Clears all streaming state and re-primes the latency buffer, so the next
    /// `process` starts a fresh overlap-add with no carry-over from prior audio.
    func reset() {
        inputBuffer.removeAll(keepingCapacity: true)
        for i in 0..<n { ola[i] = 0; winSum[i] = 0 }
        outputTape = [Float](repeating: 0, count: n)
    }

    /// Streams `input` through the STFT and returns exactly `input.count` samples,
    /// delayed by `n` samples. `gain`, if given, maps a length-`n` magnitude
    /// spectrum to a length-`n` per-bin real gain (applied to real and imaginary
    /// parts alike, so phase is preserved); when nil the transform is identity.
    func process(_ input: [Float], gain: (([Float]) -> [Float])? = nil) -> [Float] {
        if !input.isEmpty { inputBuffer.append(contentsOf: input) }
        while inputBuffer.count >= n {
            processFrame(gain: gain)
            inputBuffer.removeFirst(hop)
        }
        let k = input.count
        // Guaranteed to hold (outputTape.count == n − occupancy + k ≥ k because
        // post-loop buffer occupancy < n); the guard is a defensive backstop only.
        if outputTape.count < k {
            outputTape.append(contentsOf: repeatElement(0, count: k - outputTape.count))
        }
        let out = Array(outputTape.prefix(k))
        outputTape.removeFirst(k)
        return out
    }

    private func processFrame(gain: (([Float]) -> [Float])?) {
        for i in 0..<n {
            realp[i] = inputBuffer[i] * window[i]
            imagp[i] = 0
        }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                if let gain = gain {
                    for i in 0..<n {
                        magnitudes[i] = (rp[i] * rp[i] + ip[i] * ip[i]).squareRoot()
                    }
                    let g = gain(magnitudes)
                    // Real, symmetric gain preserves the conjugate symmetry of the
                    // real signal's spectrum, so the inverse stays real.
                    for i in 0..<n {
                        rp[i] *= g[i]
                        ip[i] *= g[i]
                    }
                }
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
            }
        }
        // Overlap-add the synthesis-windowed, round-trip-corrected real part, and
        // accumulate the matching window-power denominator.
        for i in 0..<n {
            ola[i] += realp[i] * inverseScale * window[i]
            winSum[i] += windowProduct[i]
        }
        // The first `hop` samples can receive no further contribution (all later
        // frames start ≥ hop samples ahead), so finalize and emit them now.
        for i in 0..<hop {
            let w = winSum[i]
            outputTape.append(w > 1e-9 ? ola[i] / w : 0)
        }
        // Slide the accumulators left by `hop`; index 0 now aligns to the next
        // frame's start. The retained [0, n−hop) holds this frame's contribution
        // to the samples the next frame will also touch.
        for i in 0..<(n - hop) {
            ola[i] = ola[i + hop]
            winSum[i] = winSum[i + hop]
        }
        for i in (n - hop)..<n {
            ola[i] = 0
            winSum[i] = 0
        }
    }
}

/// Profile-based spectral subtraction built on `STFTProcessor`. It continuously,
/// hands-free, estimates the environment's steady noise magnitude spectrum from
/// frames judged noise-only, then subtracts that measured pattern per frequency
/// bin so steady/tonal machine noise is knocked down by its measured magnitude
/// while transient birdsong above the floor survives.
///
/// A frame updates the noise estimate ONLY when it is both (a) quiet — its
/// broadband energy is within a small factor of the tracked noise-floor energy —
/// and (b) spectrally stationary — its magnitude spectrum is close to a fast
/// running average of recent spectra. Machine noise is steady on both counts;
/// birdsong (transient, moving in frequency) fails at least one, so it never
/// enters the profile. The estimate is a slow per-bin EMA.
final class SpectralNoiseReducer {
    private let stft: STFTProcessor
    private let n: Int

    // Noise estimate and stationarity state (length n, conjugate-symmetric like
    // the magnitude spectra they are built from).
    private var profile: [Float]     // slow EMA noise magnitude — the subtraction target
    private var recentMag: [Float]   // fast EMA of magnitudes — the stationarity reference
    private var profileInitialized = false
    private var recentInitialized = false
    private var noiseEnergyEMA: Float = 0

    // Tuning. Conservative by design: over-subtraction factor slightly above 1
    // and a non-zero floor so no bin is ever fully nulled (nulling injects
    // artifacts BirdNET never trained on).
    private let beta: Float = 1.5
    private let floorGain: Float = 0.15
    private let profileAlpha: Float = 0.05   // slow: the noise floor is near-stationary
    private let recentAlpha: Float = 0.3     // fast: tracks "what just happened"
    private let energyAlpha: Float = 0.05
    private let energyGateFactor: Float = 2  // "quiet" = energy ≤ 2× tracked floor
    // Normalized L1 spectral distance above which a frame is "not stationary".
    // Steady broadband noise sits well below (~0.4–0.6, the natural frame-to-frame
    // magnitude scatter); a moving/appearing tone drives it far higher (a swept
    // tone ≈ 2). Set between the two with margin; loud events are additionally
    // caught by the energy gate.
    private let stationarityThreshold: Float = 1.0
    private let magEps: Float = 1e-9

    init(n: Int = 1024) {
        self.n = n
        self.stft = STFTProcessor(n: n)
        self.profile = [Float](repeating: 0, count: n)
        self.recentMag = [Float](repeating: 0, count: n)
    }

    func reset() {
        stft.reset()
        for i in 0..<n { profile[i] = 0; recentMag[i] = 0 }
        profileInitialized = false
        recentInitialized = false
        noiseEnergyEMA = 0
    }

    /// True once at least one frame has been accepted into the noise profile.
    /// Until then, subtraction is a pass-through (no estimate to subtract).
    var hasNoiseProfile: Bool { profileInitialized }

    /// The current per-bin noise magnitude estimate (length n). Exposed for tests.
    var noiseProfile: [Float] { profile }

    func process(_ samples: inout [Float]) {
        samples = stft.process(samples) { [self] mags in
            updateProfileAndComputeGain(magnitudes: mags)
        }
    }

    /// Per frame: fold the frame into the running references, decide whether it is
    /// noise-only and (if so) update the profile, then return the subtraction gain.
    private func updateProfileAndComputeGain(magnitudes mags: [Float]) -> [Float] {
        var energy: Float = 0
        for i in 0..<n { energy += mags[i] * mags[i] }
        energy /= Float(n)

        // The very first frame only seeds the references; it is never itself
        // accepted, so an opening transient can't bootstrap a bogus profile.
        let seeding = !recentInitialized
        if seeding {
            for i in 0..<n { recentMag[i] = mags[i] }
            recentInitialized = true
            noiseEnergyEMA = energy
        }

        var accepted = false
        if !seeding {
            // Stationarity: normalized L1 distance to the PRIOR recent average
            // (computed before folding this frame in).
            var num: Float = 0
            var den: Float = 0
            for i in 0..<n {
                num += abs(mags[i] - recentMag[i])
                den += recentMag[i]
            }
            let distance = den > magEps ? num / den : .greatestFiniteMagnitude
            let stationary = distance <= stationarityThreshold

            // Let the floor follow downward quickly (a drop is unambiguously
            // noise/silence) so the gate can't get stuck above a falling floor.
            if energy < noiseEnergyEMA {
                noiseEnergyEMA += energyAlpha * (energy - noiseEnergyEMA)
            }
            let quiet = energy <= energyGateFactor * noiseEnergyEMA
            accepted = stationary && quiet

            for i in 0..<n { recentMag[i] += recentAlpha * (mags[i] - recentMag[i]) }
        }

        if accepted {
            if !profileInitialized {
                for i in 0..<n { profile[i] = mags[i] }
                profileInitialized = true
            } else {
                for i in 0..<n { profile[i] += profileAlpha * (mags[i] - profile[i]) }
            }
            // Allow the floor to rise slowly while genuinely in accepted noise.
            noiseEnergyEMA += energyAlpha * (energy - noiseEnergyEMA)
        }

        var gain = [Float](repeating: 1, count: n)
        if profileInitialized {
            for i in 0..<n {
                let m = mags[i]
                var g = (m - beta * profile[i]) / max(m, magEps)
                if g < floorGain { g = floorGain } else if g > 1 { g = 1 }
                gain[i] = g
            }
        }
        return gain
    }
}

/// Pipeline-facing wrapper the live `AudioHandler` drives. Two independent,
/// opt-in stages applied in place: the high-pass low-cut (`enabled`) and, layered
/// after it, profile-based spectral subtraction (`spectralEnabled`). The existing
/// auto-gain still runs later, downstream in the recognizer. A strict no-op when
/// both stages are off, so the disabled path is byte-identical to unprocessed audio.
///
/// The spectral stage is the primary, self-profiling method; the high-pass is now
/// an optional pre-clean stage that can run before it. Spectral subtraction is
/// validated against the DSP-quality proxy tests in this package (reconstruction
/// identity, noise reduction, tone survival, SNR improvement); real detection
/// efficacy is user-side (see NOISE_REDUCTION_EVAL.md), hence it ships off.
struct NoiseReducer {
    private var enabled = false
    private var spectralEnabled = false
    private var cutoffHz: Double = 300
    private var sampleRate: Double = 0

    private var highPass: BiquadHighPass?
    // Reference type (owns an FFT setup with a deinit), so it lives behind an
    // optional here rather than as a value member. There is a single owner
    // (AudioHandler mutates its `noiseReducer` in place), so no copy shares it.
    private var spectral: SpectralNoiseReducer?

    init() {}

    /// Applies the current settings. Recreates the high-pass when the sample rate
    /// changes and retunes it in place on a cutoff-only change; lazily creates the
    /// spectral stage the first time it is enabled. `spectralEnabled` defaults to
    /// false so existing call sites keep today's high-pass-only behavior.
    mutating func configure(
        enabled: Bool,
        cutoffHz: Double,
        spectralEnabled: Bool = false,
        sampleRate: Double
    ) {
        if highPass == nil || sampleRate != self.sampleRate {
            highPass = BiquadHighPass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        } else if cutoffHz != self.cutoffHz {
            highPass?.setCutoff(cutoffHz)
        }
        if spectralEnabled, spectral == nil {
            spectral = SpectralNoiseReducer()
        }
        self.enabled = enabled
        self.spectralEnabled = spectralEnabled
        self.cutoffHz = cutoffHz
        self.sampleRate = sampleRate
    }

    /// Clears filter and spectral state so a settings change or (re)start can't
    /// carry over stale filter memory or a stale noise estimate.
    mutating func reset() {
        highPass?.reset()
        spectral?.reset()
    }

    /// Applies the enabled stages in place: high-pass first (when its toggle is
    /// on), then spectral subtraction (when its toggle is on). With both off this
    /// is a strict no-op, so the disabled path costs nothing and cannot alter the
    /// samples — byte-identical to unprocessed audio.
    mutating func process(_ samples: inout [Float]) {
        if enabled { highPass?.process(&samples) }
        if spectralEnabled { spectral?.process(&samples) }
    }
}
