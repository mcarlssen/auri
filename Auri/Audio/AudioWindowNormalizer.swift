import Accelerate
import Foundation

/// Normalizes BirdNET input windows to a consistent RMS level before inference.
enum AudioWindowNormalizer {
    /// Target RMS (~-32 dBFS) for quiet desk-mic recordings.
    static let targetRMS: Float = 0.025
    static let minRMS: Float = 1e-7
    /// Maximum boost (+24 dB) to avoid amplifying silence into garbage.
    static let maxGainLinear: Float = 16

    /// Scales samples toward `targetRMS`, hard-clips to ±1. Returns applied gain in dB.
    @discardableResult
    static func applyAutoGain(to samples: inout [Float], enabled: Bool) -> Float {
        guard enabled, !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms > minRMS else { return 0 }

        let gain = min(maxGainLinear, targetRMS / rms)
        guard gain > 1.001 else { return 0 }

        var mutableGain = gain
        vDSP_vsmul(samples, 1, &mutableGain, &samples, 1, vDSP_Length(samples.count))

        var lower: Float = -1
        var upper: Float = 1
        vDSP_vclip(samples, 1, &lower, &upper, &samples, 1, vDSP_Length(samples.count))

        return 20 * log10f(gain)
    }
}
