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

    /// Load an audio file, downmix to mono, resample to 48 kHz. `AVAudioConverter`
    /// performs anti-aliased sample-rate conversion (a naive linear resample would
    /// alias high-frequency energy into the analyzed band) and the channel downmix.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat

        guard sourceFormat.channelCount >= 1 else {
            throw AudioFileLoaderError.noChannels
        }

        let sourceFrameCount = AVAudioFrameCount(file.length)
        guard sourceFrameCount > 0 else { return [] }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw AudioFileLoaderError.bufferAllocationFailed
        }
        try file.read(into: sourceBuffer)

        // Destination: mono Float32 @ 48 kHz. AVAudioConverter handles both the
        // rate conversion (with anti-alias filtering) and the channel downmix.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(modelSampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileLoaderError.noFloatData
        }

        // Size the destination by the sample-rate ratio, with a small margin for
        // the converter's internal latency.
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 1
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw AudioFileLoaderError.bufferAllocationFailed
        }

        // Feed the whole source buffer once, then report the input as drained.
        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, inputStatus in
            if providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, conversionError == nil,
              let channelData = targetBuffer.floatChannelData else {
            throw AudioFileLoaderError.noFloatData
        }

        let frames = Int(targetBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
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
}
