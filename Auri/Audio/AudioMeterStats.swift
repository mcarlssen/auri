import Accelerate
import Foundation

struct RecognitionPipelineStats: Equatable {
    var isInFlight = false
    var lastInferenceMs: Int?
    var skippedWindows: UInt64 = 0
    var belowThresholdCount: UInt64 = 0
    var lastCompletedAt: Date?
    var rollingAverageTopConfidence: Double?
    var suggestedConfidenceThreshold: Double?
    var lastAutoGainDB: Float?

    var secondsSinceLastCompletion: Double? {
        guard let lastCompletedAt else { return nil }
        return Date().timeIntervalSince(lastCompletedAt)
    }

    var isBehindRealtime: Bool {
        if isInFlight, let lastCompletedAt, Date().timeIntervalSince(lastCompletedAt) > 2.0 {
            return true
        }
        if let ms = lastInferenceMs, ms > 1_500 {
            return true
        }
        if let lag = secondsSinceLastCompletion, lag > 2.5 {
            return true
        }
        return false
    }

    var isCriticallyBehind: Bool {
        if let ms = lastInferenceMs, ms > 10_000 {
            return true
        }
        return skippedWindows >= 3
    }
}

struct AudioMeterStats: Equatable {
    var rms: Float = 0
    var peak: Float = 0
    var rmsDB: Float = -80
    var peakDB: Float = -80
    var buffersReceived: UInt64 = 0
    var isReceivingAudio: Bool = false

    static func from(samples: [Float], buffersReceived: UInt64, isReceiving: Bool) -> AudioMeterStats {
        guard !samples.isEmpty else {
            return AudioMeterStats(buffersReceived: buffersReceived, isReceivingAudio: isReceiving)
        }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        return AudioMeterStats(
            rms: rms,
            peak: peak,
            rmsDB: Self.linearToDB(rms),
            peakDB: Self.linearToDB(peak),
            buffersReceived: buffersReceived,
            isReceivingAudio: isReceiving
        )
    }

    private static func linearToDB(_ value: Float) -> Float {
        guard value > 1e-8 else { return -80 }
        return max(-80, 20 * log10(value))
    }
}
