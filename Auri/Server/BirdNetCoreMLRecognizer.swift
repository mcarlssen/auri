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

    struct SpeciesLabel: Sendable {
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
    // Reused across recognize() calls: the actor is serial, so once a prediction
    // returns the input array is free to be overwritten for the next window,
    // sparing a fresh windowSamples-float allocation every call.
    private var reusableInputArray: MLMultiArray?

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

            let config = MLModelConfiguration()
            config.computeUnits = .all
            let loadedModel = try await Self.loadCompiledModel(source: modelURL, configuration: config)

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
        reusableInputArray = nil
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
            let provider = try makeReusedInputProvider(samples: samples, featureName: inputFeatureName)
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

    /// Hot-path variant of `makeInputProvider` that reuses a single cached input
    /// array. Callers pass a window of exactly `windowSamples`, which fully
    /// overwrites the array's backing store before it is handed to the model.
    private func makeReusedInputProvider(samples: [Float], featureName: String) throws -> MLFeatureProvider {
        guard samples.count >= Self.windowSamples else {
            throw RecognizerError.invalidPCM
        }
        let array: MLMultiArray
        if let cached = reusableInputArray {
            array = cached
        } else {
            array = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
            reusableInputArray = array
        }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memcpy(array.dataPointer, base, Self.windowSamples * MemoryLayout<Float>.size)
        }
        return try MLDictionaryFeatureProvider(dictionary: [featureName: MLFeatureValue(multiArray: array)])
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

    /// Compiling the .mlpackage takes seconds and previously ran on every launch,
    /// leaving a fresh compiled copy in the temp directory each time. Cache the
    /// compiled .mlmodelc in Application Support, keyed by bundle version and the
    /// model file's modification time, and fall back to a fresh compile whenever
    /// the cache is missing or unloadable.
    private static func loadCompiledModel(
        source: URL,
        configuration: MLModelConfiguration
    ) async throws -> MLModel {
        let fileManager = FileManager.default
        var cachedURL: URL?
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let directory = support.appendingPathComponent("Auri/CompiledModels", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            let attributes = try? fileManager.attributesOfItem(atPath: source.path)
            let modifiedAt = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            let name = source.deletingPathExtension().lastPathComponent
            cachedURL = directory.appendingPathComponent(
                "\(name)-v\(version)-\(modifiedAt).mlmodelc",
                isDirectory: true
            )
        }

        if let cachedURL, fileManager.fileExists(atPath: cachedURL.path) {
            if let model = try? MLModel(contentsOf: cachedURL, configuration: configuration) {
                RecognizerLog("Loaded compiled model from cache")
                return model
            }
            RecognizerLog("Cached compiled model unloadable; recompiling")
            try? fileManager.removeItem(at: cachedURL)
        }

        let compiledURL = try await MLModel.compileModel(at: source)
        if let cachedURL {
            // Drop caches left behind by older app versions before storing this one.
            let directory = cachedURL.deletingLastPathComponent()
            if let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in contents where url.pathExtension == "mlmodelc" {
                    try? fileManager.removeItem(at: url)
                }
            }
            if (try? fileManager.moveItem(at: compiledURL, to: cachedURL)) != nil {
                return try MLModel(contentsOf: cachedURL, configuration: configuration)
            }
        }
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
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

    static func loadSpeciesLabels(from url: URL) throws -> [SpeciesLabel] {
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

    static func stableID(for label: String) -> Int {
        let digest = Insecure.SHA1.hash(data: Data(label.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Int(String(hex.prefix(8)), radix: 16) ?? 0
    }

    static func makeInputProvider(samples: [Float], featureName: String) throws -> MLFeatureProvider {
        guard samples.count >= windowSamples else {
            throw RecognizerError.invalidPCM
        }
        let array = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memcpy(array.dataPointer, base, windowSamples * MemoryLayout<Float>.size)
        }
        return try MLDictionaryFeatureProvider(dictionary: [featureName: MLFeatureValue(multiArray: array)])
    }

    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }

        let ratio = Double(targetRate) / Double(sourceRate)
        let targetCount = max(1, Int((Double(samples.count) * ratio).rounded()))

        // Downsampling folds energy above the target's Nyquist frequency back into
        // the analyzed band, so band-limit the signal before decimating. Upsampling
        // and equal rates introduce no such aliasing, so they interpolate directly.
        let source = targetRate < sourceRate
            ? lowPassFiltered(samples, cutoff: 0.5 * Double(targetRate), sampleRate: Double(sourceRate))
            : samples

        var output = [Float](repeating: 0, count: targetCount)
        for index in 0..<targetCount {
            let sourcePosition = Double(index) / ratio
            let left = Int(sourcePosition.rounded(.down))
            let right = min(left + 1, source.count - 1)
            let fraction = Float(sourcePosition - Double(left))
            output[index] = source[left] * (1 - fraction) + source[right] * fraction
        }

        return output
    }

    /// Windowed-sinc low-pass applied before decimation so content above the
    /// target Nyquist frequency can't alias into the band BirdNET analyzes. The
    /// kernel is Hann-windowed and normalized to unit DC gain, and the signal is
    /// edge-clamped rather than zero-padded, so a constant input passes through
    /// unchanged. `cutoff` and `sampleRate` are in Hz.
    private static func lowPassFiltered(_ samples: [Float], cutoff: Double, sampleRate: Double) -> [Float] {
        // Normalized cutoff in cycles/sample, kept strictly below Nyquist.
        let normalizedCutoff = min(0.499, cutoff / sampleRate)
        // Longer kernels for steeper downsampling (sharper transition), bounded to
        // keep the direct convolution's cost reasonable.
        let decimation = sampleRate / (2 * cutoff)
        let halfTaps = min(64, max(8, Int((4 * decimation).rounded())))
        let tapCount = 2 * halfTaps + 1

        var kernel = [Float](repeating: 0, count: tapCount)
        var gain: Float = 0
        for tap in 0..<tapCount {
            let offset = Double(tap - halfTaps)
            let arg = 2 * normalizedCutoff * offset
            let sinc = offset == 0 ? 1.0 : sin(Double.pi * arg) / (Double.pi * arg)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(tap) / Double(tapCount - 1))
            let value = Float(sinc * window)
            kernel[tap] = value
            gain += value
        }
        // Normalize to unit DC gain so the filter neither amplifies nor attenuates
        // steady signals.
        for tap in 0..<tapCount { kernel[tap] /= gain }

        let count = samples.count
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var accumulator: Float = 0
            for tap in 0..<tapCount {
                // Clamp out-of-range taps to the signal's edges (replication) so
                // the boundaries aren't dragged toward zero.
                let sourceIndex = min(max(index + tap - halfTaps, 0), count - 1)
                accumulator += samples[sourceIndex] * kernel[tap]
            }
            output[index] = accumulator
        }
        return output
    }

    static func fitWindow(_ samples: [Float]) -> [Float] {
        if samples.count == windowSamples { return samples }
        if samples.count > windowSamples { return Array(samples.prefix(windowSamples)) }
        return samples + [Float](repeating: 0, count: windowSamples - samples.count)
    }

    static func topPredictions(from scores: MLMultiArray, limit: Int) -> [(index: Int, score: Double)] {
        var best: [(index: Int, score: Double)] = []
        best.reserveCapacity(limit)

        func consider(_ index: Int, _ score: Double) {
            if best.count < limit {
                best.append((index, score))
                best.sort { $0.score > $1.score }
            } else if score > best[limit - 1].score {
                best[limit - 1] = (index, score)
                best.sort { $0.score > $1.score }
            }
        }

        if scores.dataType == .float32 {
            // Scanning through the typed buffer avoids boxing one NSNumber per
            // species (~6.5k allocations) on every window.
            scores.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for (index, value) in buffer.enumerated() {
                    consider(index, Double(value))
                }
            }
        } else {
            for index in 0..<scores.count {
                consider(index, scores[index].doubleValue)
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
