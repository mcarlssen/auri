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

/// Experimental spectral noise gate: STFT spectral subtraction with an adaptive
/// per-bin noise floor and a spectral floor to suppress musical noise.
///
/// This attacks steady broadband hiss that lives inside the 1–8 kHz bird band —
/// exactly where the high-pass can't help. It is gentle and never fully zeroes a
/// bin (that spectral floor is what prevents "musical noise" tones), but any
/// spectral processing introduces artifacts BirdNET never saw, so it is off by
/// default and framed as experimental. Compare detections with it on and off
/// using the retained clips.
///
/// Framing: `frameSize` 1024, Hann analysis window, 75% overlap (`hop` = N/4),
/// weighted overlap-add reconstruction normalized by the accumulated window sum
/// (robust to warmup/edge frames without hard-coding the COLA constant).
///
/// Streaming contract: `process` accepts arbitrary-length chunks and always
/// returns exactly as many samples as it was given. A sample can't be finalized
/// until the frame that ends after it has been seen, so the processed stream is
/// delayed by up to one frame; that startup gap is filled with unmodified
/// pass-through audio (never silence) so length is preserved and there is no
/// abrupt onset.
struct SpectralNoiseGate {
    private let frameSize = 1024
    private let hop = 256 // 75% overlap
    private let sampleRate: Double

    // Over-subtraction factor and spectral floor. Conservative on purpose: the
    // floor keeps a residual of every bin so suppressed bins fade rather than
    // switching fully off (which is what produces musical-noise chirps).
    private let beta: Float = 1.5
    private let floor: Float = 0.15
    // Recursive-averaging coefficient for the per-bin noise estimate (~10-frame
    // memory). A plain minimum tracker collapses onto the noise floor's *minimum*
    // magnitude — far below its mean — leaving beta*noise too small to actually
    // subtract steady noise. An exponential average settles on the noise *level*,
    // so the gate genuinely attenuates stationary hiss while brief, louder
    // transients (bird calls) ride above the lagging estimate and pass through.
    private let noiseSmoothing: Float = 0.9
    private let epsilon: Float = 1e-9

    // FFT (modern Swift wrapper over the split-complex real FFT).
    private let fft: vDSP.FFT<DSPSplitComplex>
    // Forward+inverse round-trip gain, measured empirically at init. The
    // split-complex real FFT's internal scaling convention can't be verified by
    // hand in this environment, so calibrating and dividing it out makes
    // unity-gain reconstruction exact regardless of what the constant turns out
    // to be.
    private let roundTripScale: Float
    private let window: [Float]
    private let zeroHop: [Float]

    // Persistent scratch for the pack → forward → mask → inverse → unpack path.
    private var inReal: [Float]
    private var inImag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var recon: [Float]

    // Per-bin adaptive noise-floor estimate (indices 1..<halfN are used; DC and
    // Nyquist are left untouched — DC is removed by the upstream high-pass and
    // Nyquist is the extreme edge bin).
    private var noise: [Float]
    private var noiseInitialized = false

    // Overlap-add accumulators (length `frameSize`), plus the parallel window-sum
    // used to normalize them.
    private var olaAccum: [Float]
    private var winAccum: [Float]

    // FIFOs: raw samples awaiting framing, and finalized processed samples
    // awaiting emission.
    private var inputFIFO: [Float] = []
    private var processedFIFO: [Float] = []

    // One-frame startup latency, paid down once as pass-through samples.
    private var warmupPassthroughRemaining: Int

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let halfN = frameSize / 2
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Unsupported FFT length: \(frameSize)")
        }
        self.fft = fft
        self.roundTripScale = Self.measureRoundTripScale(fft: fft, frameSize: frameSize)
        self.window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: frameSize,
            isHalfWindow: false
        )
        self.zeroHop = [Float](repeating: 0, count: hop)
        self.inReal = [Float](repeating: 0, count: halfN)
        self.inImag = [Float](repeating: 0, count: halfN)
        self.outReal = [Float](repeating: 0, count: halfN)
        self.outImag = [Float](repeating: 0, count: halfN)
        self.recon = [Float](repeating: 0, count: frameSize)
        self.noise = [Float](repeating: 0, count: halfN)
        self.olaAccum = [Float](repeating: 0, count: frameSize)
        self.winAccum = [Float](repeating: 0, count: frameSize)
        self.warmupPassthroughRemaining = frameSize
    }

    mutating func reset() {
        for i in inReal.indices { inReal[i] = 0 }
        for i in inImag.indices { inImag[i] = 0 }
        for i in outReal.indices { outReal[i] = 0 }
        for i in outImag.indices { outImag[i] = 0 }
        for i in recon.indices { recon[i] = 0 }
        for i in noise.indices { noise[i] = 0 }
        for i in olaAccum.indices { olaAccum[i] = 0 }
        for i in winAccum.indices { winAccum[i] = 0 }
        noiseInitialized = false
        inputFIFO.removeAll(keepingCapacity: true)
        processedFIFO.removeAll(keepingCapacity: true)
        warmupPassthroughRemaining = frameSize
    }

    mutating func process(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        let nIn = samples.count

        // Frame the incoming audio, finalizing `hop` processed samples per frame.
        inputFIFO.append(contentsOf: samples)
        while inputFIFO.count >= frameSize {
            processFrame()
            inputFIFO.removeFirst(hop)
        }

        // Emit exactly `nIn` samples. Startup latency (processed samples not ready
        // yet) is covered by pass-through drawn from the tail of this chunk, which
        // is precisely the newest input the delayed processed stream hasn't reached.
        var output = [Float]()
        output.reserveCapacity(nIn)
        var need = nIn

        if warmupPassthroughRemaining > 0 {
            let k = min(warmupPassthroughRemaining, need)
            output.append(contentsOf: samples[0..<k])
            warmupPassthroughRemaining -= k
            need -= k
        }

        if need > 0 {
            let k = min(need, processedFIFO.count)
            if k > 0 {
                output.append(contentsOf: processedFIFO[0..<k])
                processedFIFO.removeFirst(k)
                need -= k
            }
        }

        // Should not occur once the one-frame warmup has primed the pipeline, but
        // guard defensively: pass the tail through raw so length is always kept.
        if need > 0 {
            output.append(contentsOf: samples[(nIn - need)..<nIn])
            need = 0
        }

        samples = output
    }

    /// Windows the oldest frame in `inputFIFO`, applies the spectral gain mask,
    /// overlap-adds the reconstruction, and moves the front `hop` finalized
    /// samples into `processedFIFO`.
    private mutating func processFrame() {
        let halfN = frameSize / 2

        // Windowed frame (analysis window only; synthesis weighting is unity and
        // accounted for by the window-sum normalization below).
        var windowed = [Float](repeating: 0, count: frameSize)
        inputFIFO.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            windowed.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                for i in 0..<frameSize {
                    dstBase[i] = base[i] * window[i]
                }
            }
        }

        // Pack the real frame and run the forward FFT into `outReal`/`outImag`.
        inReal.withUnsafeMutableBufferPointer { inRealP in
            inImag.withUnsafeMutableBufferPointer { inImagP in
                outReal.withUnsafeMutableBufferPointer { outRealP in
                    outImag.withUnsafeMutableBufferPointer { outImagP in
                        var inSplit = DSPSplitComplex(
                            realp: inRealP.baseAddress!,
                            imagp: inImagP.baseAddress!
                        )
                        var outSplit = DSPSplitComplex(
                            realp: outRealP.baseAddress!,
                            imagp: outImagP.baseAddress!
                        )
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                                vDSP_ctoz(cp, 2, &inSplit, 1, vDSP_Length(halfN))
                            }
                        }
                        fft.forward(input: inSplit, output: &outSplit)
                    }
                }
            }
        }

        // Gain mask runs outside the buffer-pointer scopes: it mutates `self`
        // (noise estimate + spectrum), which would overlap the pointer accesses.
        applyGainMask()

        // Inverse FFT back into `inReal`/`inImag`, then unpack to `recon`.
        inReal.withUnsafeMutableBufferPointer { inRealP in
            inImag.withUnsafeMutableBufferPointer { inImagP in
                outReal.withUnsafeMutableBufferPointer { outRealP in
                    outImag.withUnsafeMutableBufferPointer { outImagP in
                        var inSplit = DSPSplitComplex(
                            realp: inRealP.baseAddress!,
                            imagp: inImagP.baseAddress!
                        )
                        let outSplit = DSPSplitComplex(
                            realp: outRealP.baseAddress!,
                            imagp: outImagP.baseAddress!
                        )
                        fft.inverse(input: outSplit, output: &inSplit)
                        recon.withUnsafeMutableBufferPointer { rp in
                            rp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                                vDSP_ztoc(&inSplit, 1, cp, 2, vDSP_Length(halfN))
                            }
                        }
                    }
                }
            }
        }

        // Undo the FFT round-trip gain (measured at init) so the reconstruction
        // matches the windowed input for a unity-gain mask.
        var scale = roundTripScale
        vDSP_vsmul(recon, 1, &scale, &recon, 1, vDSP_Length(frameSize))

        // Overlap-add the reconstruction and accumulate the window for
        // normalization.
        for i in 0..<frameSize {
            olaAccum[i] += recon[i]
            winAccum[i] += window[i]
        }

        // Finalize the oldest `hop` samples: divide the summed reconstruction by
        // the summed window (guarding the near-zero warmup edge).
        for i in 0..<hop {
            let w = winAccum[i]
            processedFIFO.append(w > 1e-6 ? olaAccum[i] / w : 0)
        }

        // Shift the accumulators left by one hop, zero-filling the freed tail.
        olaAccum.removeFirst(hop)
        olaAccum.append(contentsOf: zeroHop)
        winAccum.removeFirst(hop)
        winAccum.append(contentsOf: zeroHop)
    }

    /// Updates each bin's noise floor (an exponential average of magnitude) and
    /// scales the complex bin by the over-subtraction gain, preserving phase. The
    /// estimate settles on steady noise while brief, louder transients (bird
    /// calls) ride above the lagging average and pass through.
    private mutating func applyGainMask() {
        let halfN = frameSize / 2
        for k in 1..<halfN {
            let re = outReal[k]
            let im = outImag[k]
            let mag = (re * re + im * im).squareRoot()

            if !noiseInitialized {
                noise[k] = mag // seed lazily from the first frame
            } else {
                noise[k] = noiseSmoothing * noise[k] + (1 - noiseSmoothing) * mag
            }

            let subtracted = mag - beta * noise[k]
            let gain = min(1, max(floor, subtracted / max(mag, epsilon)))
            outReal[k] = re * gain
            outImag[k] = im * gain
        }
        noiseInitialized = true
    }

    /// Measures this FFT configuration's forward+inverse round-trip gain on a
    /// clean mid-band probe. The round-trip is a pure scalar multiple of the
    /// identity, so a least-squares fit of the reconstruction to the probe
    /// recovers that scalar; its reciprocal is the reconstruction scale. This
    /// sidesteps any dependence on the library's internal normalization.
    private static func measureRoundTripScale(
        fft: vDSP.FFT<DSPSplitComplex>,
        frameSize: Int
    ) -> Float {
        let halfN = frameSize / 2
        // A tone on an exact bin (no leakage), spread across samples.
        let probe = (0..<frameSize).map { i in
            cosf(2 * .pi * Float(frameSize / 8) * Float(i) / Float(frameSize))
        }
        var inReal = [Float](repeating: 0, count: halfN)
        var inImag = [Float](repeating: 0, count: halfN)
        var outReal = [Float](repeating: 0, count: halfN)
        var outImag = [Float](repeating: 0, count: halfN)
        var recon = [Float](repeating: 0, count: frameSize)

        inReal.withUnsafeMutableBufferPointer { inRealP in
            inImag.withUnsafeMutableBufferPointer { inImagP in
                outReal.withUnsafeMutableBufferPointer { outRealP in
                    outImag.withUnsafeMutableBufferPointer { outImagP in
                        var inSplit = DSPSplitComplex(
                            realp: inRealP.baseAddress!,
                            imagp: inImagP.baseAddress!
                        )
                        var outSplit = DSPSplitComplex(
                            realp: outRealP.baseAddress!,
                            imagp: outImagP.baseAddress!
                        )
                        probe.withUnsafeBufferPointer { pp in
                            pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                                vDSP_ctoz(cp, 2, &inSplit, 1, vDSP_Length(halfN))
                            }
                        }
                        fft.forward(input: inSplit, output: &outSplit)
                        fft.inverse(input: outSplit, output: &inSplit)
                        recon.withUnsafeMutableBufferPointer { rp in
                            rp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                                vDSP_ztoc(&inSplit, 1, cp, 2, vDSP_Length(halfN))
                            }
                        }
                    }
                }
            }
        }

        var dotRP: Float = 0
        var dotPP: Float = 0
        for i in 0..<frameSize {
            dotRP += recon[i] * probe[i]
            dotPP += probe[i] * probe[i]
        }
        let roundTrip = dotPP > 0 ? dotRP / dotPP : 1
        return abs(roundTrip) > 1e-20 ? 1 / roundTrip : 1
    }
}

/// Pipeline-facing wrapper the live `AudioHandler` drives. Holds the high-pass
/// and the optional spectral gate and applies them in order
/// (high-pass → gate → downstream auto-gain). A strict no-op when disabled.
struct NoiseReducer {
    private var enabled = false
    private var spectralGateEnabled = false
    private var cutoffHz: Double = 300
    private var sampleRate: Double = 0

    private var highPass: BiquadHighPass?
    private var gate: SpectralNoiseGate?

    init() {}

    /// Applies the current settings. Recreates the DSP stages when the sample rate
    /// changes and retunes the high-pass in place on a cutoff-only change.
    mutating func configure(
        enabled: Bool,
        cutoffHz: Double,
        spectralGateEnabled: Bool,
        sampleRate: Double
    ) {
        if highPass == nil || sampleRate != self.sampleRate {
            highPass = BiquadHighPass(cutoffHz: cutoffHz, sampleRate: sampleRate)
            gate = SpectralNoiseGate(sampleRate: sampleRate)
        } else if cutoffHz != self.cutoffHz {
            highPass?.setCutoff(cutoffHz)
        }
        self.enabled = enabled
        self.spectralGateEnabled = spectralGateEnabled
        self.cutoffHz = cutoffHz
        self.sampleRate = sampleRate
    }

    mutating func reset() {
        highPass?.reset()
        gate?.reset()
    }

    /// High-pass, then the optional spectral gate, in place. No-op when disabled
    /// so the off path costs nothing and can't alter the samples.
    mutating func process(_ samples: inout [Float]) {
        guard enabled else { return }
        highPass?.process(&samples)
        if spectralGateEnabled {
            gate?.process(&samples)
        }
    }
}
