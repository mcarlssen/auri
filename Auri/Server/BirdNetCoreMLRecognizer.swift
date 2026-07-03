import CoreML
import CryptoKit
import Foundation

private func RecognizerLog(_ message: @autoclosure () -> String) {
    RecognitionLogger.log(message())
}

actor BirdNetCoreMLRecognizer {
    enum State: Equatable {
        case stopped
        case loading
        case ready
        case failed(String)
    }

    static let modelSampleRate = 48_000
    static let windowSamples = modelSampleRate * 3

    struct RecognitionCallResult: Sendable {
        let detections: [RecognitionResponse]
        let inferenceMs: Int
        let autoGainDB: Float

        var detection: RecognitionResponse? { detections.first }
    }

    static let maxResultsPerWindow = 10

    private struct SpeciesLabel: Sendable {
        let raw: String
        let scientificName: String
        let commonName: String
        let id: Int
    }

    private var state: State = .stopped
    private var model: MLModel?
    private var inputFeatureName: String?
    private var speciesLabels: [SpeciesLabel] = []
    private var speciesCatalogEntries: [Bird] = []

    func currentState() -> State {
        state
    }

    func start() async {
        guard state == .stopped || state.isFailed else { return }
        state = .loading
        RecognizerLog("Loading BirdNET Core ML model…")

        do {
            let bundle = Bundle.main
            guard let modelURL = Self.resourceURL(
                in: bundle,
                name: "audio-model-fp16",
                ext: "mlpackage",
                subdirectories: [nil, "BirdNet"]
            ) else {
                throw RecognizerError.missingModel
            }

            guard let labelsURL = Self.resourceURL(
                in: bundle,
                name: "en_us",
                ext: "txt",
                subdirectories: [nil, "BirdNet/labels", "labels"]
            ) else {
                throw RecognizerError.missingLabels
            }

            let labels = try Self.loadSpeciesLabels(from: labelsURL)
            let compiledURL = try await MLModel.compileModel(at: modelURL)

            let config = MLModelConfiguration()
            config.computeUnits = .all
            let loadedModel = try MLModel(contentsOf: compiledURL, configuration: config)

            guard let inputName = loadedModel.modelDescription.inputDescriptionsByName.keys.first else {
                throw RecognizerError.invalidModel("Model has no inputs")
            }

            let silence = [Float](repeating: 0, count: Self.windowSamples)
            try autoreleasepool {
                let warmupProvider = try Self.makeInputProvider(
                    samples: silence,
                    featureName: inputName
                )
                _ = try loadedModel.prediction(from: warmupProvider)
            }

            model = loadedModel
            inputFeatureName = inputName
            speciesLabels = labels
            speciesCatalogEntries = labels.map {
                Bird(id: $0.id, commonName: $0.commonName, scientificName: $0.scientificName)
            }
            state = .ready
            RecognizerLog("BirdNET Core ML ready (\(labels.count) species)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            RecognizerLog("Failed to load model: \(message)")
        }
    }

    func stop() {
        model = nil
        inputFeatureName = nil
        speciesLabels = []
        speciesCatalogEntries = []
        state = .stopped
    }

    func speciesCatalog() -> [Bird] {
        speciesCatalogEntries
    }

    func recognize(pcmData: Data, sampleRate: Int, applyAutoGain: Bool = true) async throws -> RecognitionCallResult {
        guard state == .ready else {
            throw RecognizerError.notReady
        }
        guard let model, let inputFeatureName else {
            throw RecognizerError.notReady
        }
        guard !pcmData.isEmpty else {
            return RecognitionCallResult(detections: [], inferenceMs: 0, autoGainDB: 0)
        }
        guard pcmData.count % MemoryLayout<Float>.size == 0 else {
            throw RecognizerError.invalidPCM
        }

        let sampleCount = pcmData.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { rawBuffer in
            pcmData.copyBytes(to: rawBuffer)
        }

        if sampleRate != Self.modelSampleRate {
            samples = Self.resample(samples, from: sampleRate, to: Self.modelSampleRate)
        }
        samples = Self.fitWindow(samples)
        let appliedAutoGainDB = AudioWindowNormalizer.applyAutoGain(to: &samples, enabled: applyAutoGain)
        if applyAutoGain, appliedAutoGainDB > 0.1 {
            RecognizerLog(String(format: "auto-gain +%.1f dB", appliedAutoGainDB))
        }

        RecognizerLog("recognize samples=\(samples.count) sr=\(sampleRate)")
        let started = CFAbsoluteTimeGetCurrent()
        // The prediction's IOSurface-backed input/output buffers are autoreleased,
        // and this actor's cooperative thread never drains its pool on its own, so
        // every window leaks its buffers until the pool is drained explicitly.
        // Extract plain Swift values before leaving the pool.
        let predictions: [(index: Int, score: Double)] = try autoreleasepool {
            let provider = try Self.makeInputProvider(samples: samples, featureName: inputFeatureName)
            let output = try model.prediction(from: provider)
            guard let outputName = output.featureNames.first,
                  let value = output.featureValue(for: outputName),
                  let scores = value.multiArrayValue else {
                return []
            }
            return Self.topPredictions(from: scores, limit: Self.maxResultsPerWindow)
        }
        let inferenceMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        RecognizerLog("inference finished \(inferenceMs)ms")
        let detections = predictions.compactMap { prediction -> RecognitionResponse? in
            guard let label = speciesLabels[safe: prediction.index] else { return nil }
            return RecognitionResponse(
                bird: label.commonName,
                id: label.id,
                confidence: prediction.score,
                score: prediction.score,
                timeMs: inferenceMs,
                scientificName: label.scientificName
            )
        }
        return RecognitionCallResult(detections: detections, inferenceMs: inferenceMs, autoGainDB: appliedAutoGainDB)
    }

    private enum RecognizerError: Error, LocalizedError {
        case missingModel
        case missingLabels
        case invalidModel(String)
        case notReady
        case invalidPCM

        var errorDescription: String? {
            switch self {
            case .missingModel:
                return "BirdNET Core ML model not found in app bundle."
            case .missingLabels:
                return "BirdNET species labels not found in app bundle."
            case .invalidModel(let message):
                return message
            case .notReady:
                return "BirdNET model is not ready."
            case .invalidPCM:
                return "PCM byte length must be a multiple of 4."
            }
        }
    }

    private static func resourceURL(
        in bundle: Bundle,
        name: String,
        ext: String,
        subdirectories: [String?]
    ) -> URL? {
        for subdirectory in subdirectories {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }

    private static func loadSpeciesLabels(from url: URL) throws -> [SpeciesLabel] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { raw in
                let scientific: String
                let common: String
                if let separator = raw.firstIndex(of: "_") {
                    scientific = String(raw[..<separator])
                    common = String(raw[raw.index(after: separator)...])
                } else {
                    scientific = raw
                    common = raw
                }
                return SpeciesLabel(
                    raw: raw,
                    scientificName: scientific,
                    commonName: common,
                    id: stableID(for: raw)
                )
            }
    }

    private static func stableID(for label: String) -> Int {
        let digest = Insecure.SHA1.hash(data: Data(label.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Int(String(hex.prefix(8)), radix: 16) ?? 0
    }

    private static func makeInputProvider(samples: [Float], featureName: String) throws -> MLFeatureProvider {
        let array = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: windowSamples)
        for index in 0..<windowSamples {
            pointer[index] = samples[index]
        }
        return try MLDictionaryFeatureProvider(dictionary: [featureName: MLFeatureValue(multiArray: array)])
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

    private static func fitWindow(_ samples: [Float]) -> [Float] {
        if samples.count == windowSamples { return samples }
        if samples.count > windowSamples { return Array(samples.prefix(windowSamples)) }
        return samples + [Float](repeating: 0, count: windowSamples - samples.count)
    }

    private static func topPredictions(from scores: MLMultiArray, limit: Int) -> [(index: Int, score: Double)] {
        let count = scores.count
        var best: [(index: Int, score: Double)] = []
        best.reserveCapacity(limit)

        for index in 0..<count {
            let score = scores[index].doubleValue
            if best.count < limit {
                best.append((index, score))
                best.sort { $0.score > $1.score }
            } else if score > best.last!.score {
                best[limit - 1] = (index, score)
                best.sort { $0.score > $1.score }
            }
        }

        return best
    }
}

private extension BirdNetCoreMLRecognizer.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
