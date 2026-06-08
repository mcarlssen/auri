import AVFoundation
import Foundation

enum AudioFileLoaderError: Error, LocalizedError {
    case noChannels
    case bufferAllocationFailed
    case noFloatData

    var errorDescription: String? {
        switch self {
        case .noChannels: return "Audio file has no channels."
        case .bufferAllocationFailed: return "Could not allocate PCM buffer."
        case .noFloatData: return "Could not read float channel data."
        }
    }
}

enum AudioFileLoader {
    static let modelSampleRate = BirdNetCoreMLRecognizer.modelSampleRate
    static let windowSamples = BirdNetCoreMLRecognizer.windowSamples

    /// Load an audio file, downmix to mono, resample to 48 kHz.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        guard format.channelCount >= 1 else {
            throw AudioFileLoaderError.noChannels
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioFileLoaderError.bufferAllocationFailed
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw AudioFileLoaderError.noFloatData
        }

        let frames = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frames)
        let channels = Int(format.channelCount)
        for channel in 0..<channels {
            let data = channelData[channel]
            for index in 0..<frames {
                mono[index] += data[index] / Float(channels)
            }
        }

        let sourceRate = Int(format.sampleRate.rounded())
        return resample(mono, from: sourceRate, to: modelSampleRate)
    }

    /// Split samples into 3-second windows. The last window is zero-padded if needed.
    /// `hopSamples` controls overlap; defaults to non-overlapping windows.
    static func windows(from samples: [Float], hopSamples: Int = windowSamples) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        let hop = max(1, min(hopSamples, windowSamples))
        var result: [[Float]] = []
        var offset = 0
        while offset < samples.count {
            var window = Array(samples[offset..<min(offset + windowSamples, samples.count)])
            if window.count < windowSamples {
                window += [Float](repeating: 0, count: windowSamples - window.count)
            }
            result.append(window)
            if offset + windowSamples >= samples.count { break }
            offset += hop
        }
        return result
    }

    static func offsetSeconds(forWindowIndex index: Int, hopSamples: Int) -> Double {
        Double(index * hopSamples) / Double(modelSampleRate)
    }

    static func pcmData(from samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }

        let ratio = Double(targetRate) / Double(sourceRate)
        let targetCount = max(1, Int((Double(samples.count) * ratio).rounded()))
        var output = [Float](repeating: 0, count: targetCount)

        for index in 0..<targetCount {
            let sourcePosition = Double(index) / ratio
            let left = Int(sourcePosition.rounded(.down))
            let right = min(left + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(left))
            output[index] = samples[left] * (1 - fraction) + samples[right] * fraction
        }

        return output
    }
}
