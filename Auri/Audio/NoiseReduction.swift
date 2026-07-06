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

/// Pipeline-facing wrapper the live `AudioHandler` drives. Applies the high-pass
/// low-cut in place; the existing auto-gain still runs later, downstream in the
/// recognizer. A strict no-op when disabled.
///
/// An experimental spectral noise gate was prototyped here but is deferred to a
/// follow-up branch where it will be rebuilt as the primary, self-profiling
/// method and validated against a detection-accuracy harness; this type is
/// intentionally a thin high-pass wrapper for now so the reducer's shape stays
/// stable when the gate returns.
struct NoiseReducer {
    private var enabled = false
    private var cutoffHz: Double = 300
    private var sampleRate: Double = 0

    private var highPass: BiquadHighPass?

    init() {}

    /// Applies the current settings. Recreates the high-pass when the sample rate
    /// changes and retunes it in place on a cutoff-only change.
    mutating func configure(
        enabled: Bool,
        cutoffHz: Double,
        sampleRate: Double
    ) {
        if highPass == nil || sampleRate != self.sampleRate {
            highPass = BiquadHighPass(cutoffHz: cutoffHz, sampleRate: sampleRate)
        } else if cutoffHz != self.cutoffHz {
            highPass?.setCutoff(cutoffHz)
        }
        self.enabled = enabled
        self.cutoffHz = cutoffHz
        self.sampleRate = sampleRate
    }

    mutating func reset() {
        highPass?.reset()
    }

    /// Applies the high-pass in place. No-op when disabled so the off path costs
    /// nothing and can't alter the samples.
    mutating func process(_ samples: inout [Float]) {
        guard enabled else { return }
        highPass?.process(&samples)
    }
}
