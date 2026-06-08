import AVFoundation
import CoreML
import Foundation

private let sampleRate = 48_000
private let windowSamples = sampleRate * 3

struct CLI {
    var modelPath: URL
    var audioPath: URL?
    var runs: Int
    var labelsPath: URL?
    var computeUnits: MLComputeUnits
}

func parseCLI() throws -> CLI {
    var modelPath: URL?
    var audioPath: URL?
    var labelsPath: URL?
    var runs = 5
    var computeUnits: MLComputeUnits = .all
    var args = Array(CommandLine.arguments.dropFirst())

    while let flag = args.first {
        args.removeFirst()
        switch flag {
        case "--model":
            guard let value = args.first else { throw SpikeError.missingValue("--model") }
            args.removeFirst()
            modelPath = URL(fileURLWithPath: value)
        case "--audio":
            guard let value = args.first else { throw SpikeError.missingValue("--audio") }
            args.removeFirst()
            audioPath = URL(fileURLWithPath: value)
        case "--labels":
            guard let value = args.first else { throw SpikeError.missingValue("--labels") }
            args.removeFirst()
            labelsPath = URL(fileURLWithPath: value)
        case "--runs":
            guard let value = args.first, let parsed = Int(value), parsed > 0 else {
                throw SpikeError.invalidRuns
            }
            args.removeFirst()
            runs = parsed
        case "--compute-units":
            guard let value = args.first else { throw SpikeError.missingValue("--compute-units") }
            args.removeFirst()
            switch value.lowercased() {
            case "all": computeUnits = .all
            case "cpu": computeUnits = .cpuOnly
            case "cpuandgpu": computeUnits = .cpuAndGPU
            case "cpuandne", "cpuandneuralengine": computeUnits = .cpuAndNeuralEngine
            default: throw SpikeError.unknownFlag("--compute-units \(value)")
            }
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw SpikeError.unknownFlag(flag)
        }
    }

    guard let modelPath else {
        printUsage()
        throw SpikeError.missingModel
    }

    return CLI(
        modelPath: modelPath,
        audioPath: audioPath,
        runs: runs,
        labelsPath: labelsPath,
        computeUnits: computeUnits
    )
}

enum SpikeError: Error, CustomStringConvertible {
    case missingValue(String)
    case missingModel
    case unknownFlag(String)
    case invalidRuns
    case audioLoadFailed(String)
    case modelLoadFailed(String)
    case predictionFailed(String)

    var description: String {
        switch self {
        case .missingValue(let flag): return "Missing value for \(flag)"
        case .missingModel: return "Missing required --model path"
        case .unknownFlag(let flag): return "Unknown flag: \(flag)"
        case .invalidRuns: return "--runs must be a positive integer"
        case .audioLoadFailed(let message): return "Failed to load audio: \(message)"
        case .modelLoadFailed(let message): return "Failed to load model: \(message)"
        case .predictionFailed(let message): return "Prediction failed: \(message)"
        }
    }
}

func printUsage() {
    print(
        """
        CoreMLSpike — benchmark BirdNET Core ML inference on macOS

        Usage:
          swift run CoreMLSpike --model <path/to/audio-model-fp16.mlpackage> [options]

        Options:
          --audio <wav>     3s mono WAV at 48 kHz (default: generated silence)
          --labels <txt>    BirdNET label file for top-k decoding
          --runs <n>        Timed inference iterations after warmup (default: 5)
          --compute-units   all | cpu | cpuAndGPU | cpuAndNeuralEngine (default: all)
          --help            Show this help
        """
    )
}

func loadLabels(from url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

func loadAudioWindow(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat

    guard format.channelCount >= 1 else {
        throw SpikeError.audioLoadFailed("Expected at least one channel")
    }

    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw SpikeError.audioLoadFailed("Could not allocate PCM buffer")
    }
    try file.read(into: buffer)
    guard let channelData = buffer.floatChannelData else {
        throw SpikeError.audioLoadFailed("Could not read float channel data")
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
    let resampled = resample(mono, from: sourceRate, to: sampleRate)
    return fitWindow(resampled)
}

func silenceWindow() -> [Float] {
    [Float](repeating: 0, count: windowSamples)
}

func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
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

func fitWindow(_ samples: [Float]) -> [Float] {
    if samples.count == windowSamples { return samples }
    if samples.count > windowSamples { return Array(samples.prefix(windowSamples)) }
    return samples + [Float](repeating: 0, count: windowSamples - samples.count)
}

func makeInputProvider(samples: [Float], featureName: String) throws -> MLFeatureProvider {
    let array = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
    let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: windowSamples)
    for index in 0..<windowSamples {
        pointer[index] = samples[index]
    }
    let value = MLFeatureValue(multiArray: array)
    return try MLDictionaryFeatureProvider(dictionary: [featureName: value])
}

func topPrediction(from output: MLFeatureProvider, labels: [String], count: Int = 3) -> String {
    guard let first = output.featureNames.first,
          let value = output.featureValue(for: first),
          let scores = value.multiArrayValue else {
        return "no output"
    }

    let length = scores.count
    var best: [(Int, Double)] = []
    for index in 0..<length {
        let score = scores[index].doubleValue
        if best.count < count {
            best.append((index, score))
            best.sort { $0.1 > $1.1 }
        } else if score > best.last!.1 {
            best[count - 1] = (index, score)
            best.sort { $0.1 > $1.1 }
        }
    }

    return best.map { index, score in
        let label = index < labels.count ? labels[index] : "index-\(index)"
        return String(format: "%.4f %@", score, label)
    }.joined(separator: ", ")
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

@main
struct CoreMLSpike {
    static func main() {
        do {
            let cli = try parseCLI()
            let labels = cli.labelsPath.map(loadLabels(from:)) ?? []

            let config = MLModelConfiguration()
            config.computeUnits = cli.computeUnits

            let compiledURL: URL
            if cli.modelPath.pathExtension == "mlpackage" {
                compiledURL = try MLModel.compileModel(at: cli.modelPath)
            } else {
                compiledURL = cli.modelPath
            }

            let loadStarted = CFAbsoluteTimeGetCurrent()
            let model = try MLModel(contentsOf: compiledURL, configuration: config)
            let loadMs = (CFAbsoluteTimeGetCurrent() - loadStarted) * 1000

            guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
                throw SpikeError.modelLoadFailed("Model has no inputs")
            }
            let outputNames = model.modelDescription.outputDescriptionsByName.keys.sorted()
            let window: [Float]
            if let audioPath = cli.audioPath {
                window = try loadAudioWindow(from: audioPath)
            } else {
                window = silenceWindow()
            }

            print("Model: \(cli.modelPath.path)")
            print("Load: \(Int(loadMs)) ms")
            print("Input: \(inputName) shape [1, \(windowSamples)] @ \(sampleRate) Hz")
            print("Outputs: \(outputNames.joined(separator: ", "))")
            print("Compute units: \(cli.computeUnits)")

            let warmupProvider = try makeInputProvider(samples: window, featureName: inputName)
            _ = try model.prediction(from: warmupProvider)

            var timings: [Double] = []
            var lastOutput: MLFeatureProvider?
            for _ in 0..<cli.runs {
                let started = CFAbsoluteTimeGetCurrent()
                let provider = try makeInputProvider(samples: window, featureName: inputName)
                lastOutput = try model.prediction(from: provider)
                timings.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            }

            let avg = timings.reduce(0, +) / Double(timings.count)
            let min = timings.min() ?? 0
            let max = timings.max() ?? 0
            let med = median(timings)

            print("\nInference (\(cli.runs) runs after warmup):")
            print(String(format: "  min: %.0f ms", min))
            print(String(format: "  median: %.0f ms", med))
            print(String(format: "  avg: %.0f ms", avg))
            print(String(format: "  max: %.0f ms", max))
            print(String(format: "  per-run: %@", timings.map { String(format: "%.0f", $0) }.joined(separator: ", ")))

            if let lastOutput, !labels.isEmpty {
                print("Top predictions: \(topPrediction(from: lastOutput, labels: labels))")
            }

            print("\nBaseline reference: Python birdnet TF CPU ~7,000–11,000 ms per 3s window on M1")
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }
}
