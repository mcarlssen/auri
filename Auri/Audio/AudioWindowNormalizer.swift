import Accelerate
import Foundation

/// Normalizes BirdNET input windows to a consistent RMS level before inference.
enum AudioWindowNormalizer {
    /// Target RMS (~-32 dBFS) for quiet desk-mic recordings.
    static let targetRMS: Float = 0.025
    static let minRMS: Float = 1e-7
    /// Maximum boost (+24 dB) to avoid amplifying silence into garbage.
    static let maxGainLinear: Float = 16

    /// Scales samples toward `targetRMS`, capping the applied gain so the window's
    /// peak never exceeds ±1 (peak-safe: no hard clipping, no added distortion).
    /// Returns applied gain in dB.
    @discardableResult
    static func applyAutoGain(to samples: inout [Float], enabled: Bool) -> Float {
        guard enabled, !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms > minRMS else { return 0 }

        let rmsGain = min(maxGainLinear, targetRMS / rms)

        // Cap the gain so the loudest sample lands at exactly 1.0 rather than being
        // clipped past it, which would inject harmonic distortion the model never saw.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        let effectiveGain = min(rmsGain, peak > 0 ? 1 / peak : rmsGain)
        guard effectiveGain > 1.001 else { return 0 }

        var mutableGain = effectiveGain
        vDSP_vsmul(samples, 1, &mutableGain, &samples, 1, vDSP_Length(samples.count))

        return 20 * log10f(effectiveGain)
    }
}
