import Accelerate
import CoreGraphics
import Foundation

struct SpectrogramConfiguration: Equatable {
    let sampleRate: Int
    let fftSize: Int
    let hopSize: Int
    let historySeconds: Float
    let minFrequency: Float
    let maxFrequency: Float
    let frequencyScale: SpectrogramFrequencyScale

    init(
        sampleRate: Int = BirdNetCoreMLRecognizer.modelSampleRate,
        fftSize: Int,
        hopSize: Int,
        historySeconds: Float = 5,
        minFrequency: Float,
        maxFrequency: Float,
        frequencyScale: SpectrogramFrequencyScale
    ) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.historySeconds = historySeconds
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.frequencyScale = frequencyScale
    }

    @MainActor
    static func displayMonitor(settings: AppSettings, sampleRate: Int = BirdNetCoreMLRecognizer.modelSampleRate) -> SpectrogramConfiguration {
        SpectrogramConfiguration(
            sampleRate: sampleRate,
            fftSize: SpectrogramEngine.displayFFTSize,
            hopSize: SpectrogramEngine.displayHopSize(sampleRate: sampleRate),
            historySeconds: SpectrogramEngine.historySeconds,
            minFrequency: Float(settings.spectrogramMinFrequency),
            maxFrequency: Float(settings.spectrogramMaxFrequency),
            frequencyScale: settings.spectrogramFrequencyScale
        )
    }

    static let `default` = SpectrogramConfiguration(
        fftSize: SpectrogramEngine.displayFFTSize,
        hopSize: SpectrogramEngine.displayHopSize(),
        minFrequency: 100,
        maxFrequency: 15_000,
        frequencyScale: .mel
    )

    func requiresAnalysisRebuild(comparedTo other: SpectrogramConfiguration?) -> Bool {
        guard let other else { return true }
        return sampleRate != other.sampleRate
            || fftSize != other.fftSize
            || hopSize != other.hopSize
    }
}

/// Fast display-only scrolling spectrogram (BirdNET uses a separate audio path).
final class SpectrogramEngine {
    static let displayFFTSize = 1024
    static let displayWidth = 512
    static let displayHeight = 192
    static let historySeconds: Float = 5

    static func displayHopSize(
        sampleRate: Int = BirdNetCoreMLRecognizer.modelSampleRate,
        historySeconds: Float = historySeconds,
        displayWidth: Int = displayWidth
    ) -> Int {
        max(1, Int((Float(sampleRate) * historySeconds) / Float(displayWidth)))
    }

    struct Snapshot {
        let cgImage: CGImage
        let width: Int
        let height: Int
        let version: UInt64
        let historySeconds: Float
        let minFrequency: Float
        let maxFrequency: Float
        let frequencyScale: SpectrogramFrequencyScale
    }

    private let sampleRate: Int
    private let sampleCount: Int
    private let hopCount: Int
    private let displayWidth: Int
    private let displayHeight: Int
    private let historySeconds: Float
    private var minFrequency: Float
    private var maxFrequency: Float
    private var frequencyScale: SpectrogramFrequencyScale
    private let maxRawBacklogSamples: Int
    private let minDB: Float = -120
    private let maxDB: Float = -20

    private let fftLog2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let hanningWindow: [Float]
    private var fftInput: [Float]
    private var fftReal: [Float]
    private var fftImag: [Float]
    private var powerSpectrum: [Float]

    private var rawAudioData: [Float] = []
    private var rawAudioReadIndex = 0
    private var columnRing: [[Float]]
    private let emptyColumn: [Float]
    private var columnWriteIndex = 0
    private var columnsFilled = 0
    private var totalColumnsWritten: UInt64 = 0
    private var rgbaPixels: [UInt8]
    private var version: UInt64 = 0
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let emptyCGImage: CGImage

    init(configuration: SpectrogramConfiguration) {
        self.sampleRate = configuration.sampleRate
        self.sampleCount = configuration.fftSize
        self.hopCount = max(1, configuration.hopSize)
        self.displayWidth = Self.displayWidth
        self.displayHeight = Self.displayHeight
        self.historySeconds = configuration.historySeconds
        self.minFrequency = configuration.minFrequency
        self.maxFrequency = configuration.maxFrequency
        self.frequencyScale = configuration.frequencyScale
        self.maxRawBacklogSamples = self.hopCount * self.displayWidth + self.sampleCount

        let log2n = vDSP_Length(log2(Double(sampleCount)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Unsupported FFT length: \(sampleCount)")
        }
        self.fftLog2n = log2n
        self.fftSetup = setup
        self.hanningWindow = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: sampleCount,
            isHalfWindow: false
        )
        self.fftInput = [Float](repeating: 0, count: sampleCount)
        self.fftReal = [Float](repeating: 0, count: sampleCount / 2)
        self.fftImag = [Float](repeating: 0, count: sampleCount / 2)
        self.powerSpectrum = [Float](repeating: 0, count: sampleCount / 2)
        self.emptyColumn = [Float](repeating: 0, count: Self.displayHeight)
        self.columnRing = (0..<Self.displayWidth).map { _ in
            [Float](repeating: 0, count: Self.displayHeight)
        }
        self.rgbaPixels = [UInt8](repeating: 0, count: Self.displayWidth * Self.displayHeight * 4)
        self.emptyCGImage = Self.makeRGBCGImage(
            pixels: rgbaPixels,
            width: Self.displayWidth,
            height: Self.displayHeight,
            colorSpace: rgbColorSpace
        ) ?? Self.fallbackImage()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    var filledColumnCount: Int {
        columnsFilled
    }

    /// Monotonic count of columns written; used to detect ring-buffer scroll updates after `columnsFilled` caps.
    var columnGeneration: UInt64 {
        totalColumnsWritten
    }

    func resetBuffer() {
        rawAudioData.removeAll(keepingCapacity: true)
        rawAudioReadIndex = 0
        columnWriteIndex = 0
        columnsFilled = 0
        totalColumnsWritten = 0
        for index in columnRing.indices {
            columnRing[index] = [Float](repeating: 0, count: displayHeight)
        }
    }

    func discardBacklogIfBehind() {
        let unread = availableRawSamples
        guard unread > maxRawBacklogSamples else { return }
        rawAudioReadIndex += unread - maxRawBacklogSamples
        clampReadIndex()
        compactRawAudioIfNeeded()
    }

    func ingest(samples: [Float]) -> Int {
        guard !samples.isEmpty else { return 0 }
        rawAudioData.append(contentsOf: samples)
        clampReadIndex()
        compactRawAudioIfNeeded()
        discardBacklogIfBehind()

        var columnsWritten = 0
        while availableRawSamples >= sampleCount {
            processFrame(startIndex: rawAudioReadIndex)
            rawAudioReadIndex += hopCount
            clampReadIndex()
            compactRawAudioIfNeeded()
            columnsWritten += 1
        }

        return columnsWritten
    }

    func applyDisplayConfiguration(_ configuration: SpectrogramConfiguration) {
        minFrequency = configuration.minFrequency
        maxFrequency = configuration.maxFrequency
        frequencyScale = configuration.frequencyScale
    }

    func makeSnapshot() -> Snapshot {
        version &+= 1
        renderPixels()
        let image = Self.makeRGBCGImage(
            pixels: rgbaPixels,
            width: displayWidth,
            height: displayHeight,
            colorSpace: rgbColorSpace
        ) ?? emptyCGImage
        return Snapshot(
            cgImage: image,
            width: displayWidth,
            height: displayHeight,
            version: version,
            historySeconds: historySeconds,
            minFrequency: minFrequency,
            maxFrequency: maxFrequency,
            frequencyScale: frequencyScale
        )
    }

    private var availableRawSamples: Int {
        max(0, rawAudioData.count - rawAudioReadIndex)
    }

    private func clampReadIndex() {
        if rawAudioReadIndex > rawAudioData.count {
            compactConsumedPrefix()
        }
    }

    private func compactConsumedPrefix() {
        guard rawAudioReadIndex > 0, !rawAudioData.isEmpty else {
            rawAudioReadIndex = 0
            return
        }
        let removable = min(rawAudioReadIndex, rawAudioData.count)
        rawAudioData.removeFirst(removable)
        rawAudioReadIndex -= removable
    }

    private func compactRawAudioIfNeeded() {
        guard rawAudioReadIndex > 32_768 else { return }
        compactConsumedPrefix()
    }

    private func processFrame(startIndex: Int) {
        guard startIndex >= 0, startIndex + sampleCount <= rawAudioData.count else { return }
        rawAudioData.withUnsafeBufferPointer { raw in
            fftInput.withUnsafeMutableBufferPointer { input in
                guard let rawBase = raw.baseAddress, let inputBase = input.baseAddress else { return }
                memcpy(inputBase, rawBase.advanced(by: startIndex), sampleCount * MemoryLayout<Float>.size)
            }
        }

        vDSP.multiply(fftInput, hanningWindow, result: &fftInput)

        fftInput.withUnsafeBufferPointer { input in
            fftReal.withUnsafeMutableBufferPointer { real in
                fftImag.withUnsafeMutableBufferPointer { imag in
                    guard let inputBase = input.baseAddress,
                          let realBase = real.baseAddress,
                          let imagBase = imag.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    inputBase.withMemoryRebound(to: DSPComplex.self, capacity: sampleCount / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(sampleCount / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                    var scale = Float(1.0 / Float(sampleCount))
                    vDSP_vsmul(realBase, 1, &scale, realBase, 1, vDSP_Length(sampleCount / 2))
                    vDSP_vsmul(imagBase, 1, &scale, imagBase, 1, vDSP_Length(sampleCount / 2))
                    vDSP_zvmags(&split, 1, &powerSpectrum, 1, vDSP_Length(sampleCount / 2))
                }
            }
        }

        let binCount = sampleCount / 2

        var column = [Float](repeating: 0, count: displayHeight)
        let nyquist = Float(sampleRate) / 2
        let displayMaxFrequency = min(maxFrequency, nyquist * 0.98)

        for bin in 0..<binCount {
            let frequency = Float(bin) * nyquist / Float(binCount)
            guard frequency >= minFrequency, frequency <= displayMaxFrequency else { continue }

            let db = 10 * log10f(max(powerSpectrum[bin], 1e-16))
            let normalized = normalizedPower(db)
            let displayBin = displayBinIndex(for: frequency, maxFrequency: displayMaxFrequency)
            guard displayBin >= 0, displayBin < displayHeight else { continue }
            column[displayBin] = max(column[displayBin], normalized)
        }

        normalizeColumnPeak(&column)
        storeColumn(column)
    }

    private func normalizeColumnPeak(_ column: inout [Float]) {
        guard let peak = column.max(), peak > 1e-6 else { return }
        let invPeak = 1 / peak
        for index in column.indices {
            column[index] *= invPeak
        }
    }

    private func normalizedPower(_ db: Float) -> Float {
        max(0, min(1, (db - minDB) / (maxDB - minDB)))
    }

    private func storeColumn(_ column: [Float]) {
        columnRing[columnWriteIndex] = column
        columnWriteIndex = (columnWriteIndex + 1) % displayWidth
        columnsFilled = min(columnsFilled + 1, displayWidth)
        totalColumnsWritten &+= 1
    }

    private func column(atAge age: Int) -> [Float] {
        guard age < columnsFilled else { return emptyColumn }
        let ringIndex = (columnWriteIndex - 1 - age + displayWidth * 8) % displayWidth
        return columnRing[ringIndex]
    }

    private func displayBinIndex(for frequency: Float, maxFrequency: Float) -> Int {
        let position = frequencyScale.displayPosition(
            for: frequency,
            minHz: minFrequency,
            maxHz: maxFrequency
        )
        return Int(max(0, min(1, position)) * Float(displayHeight - 1))
    }

    private func renderPixels() {
        let width = displayWidth
        let height = displayHeight

        for displayX in 0..<width {
            let age = width - 1 - displayX
            let sourceColumn = column(atAge: age)
            for row in 0..<height {
                let freqIndex = height - 1 - row
                let value = sourceColumn[freqIndex]
                let shade = UInt8(clamping: Int(value * 255))
                // CGContext origin is bottom-left; write rows accordingly.
                let offset = ((height - 1 - row) * width + displayX) * 4
                rgbaPixels[offset] = shade
                rgbaPixels[offset + 1] = shade
                rgbaPixels[offset + 2] = shade
                rgbaPixels[offset + 3] = 255
            }
        }
    }

    private static func makeRGBCGImage(
        pixels: [UInt8],
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        var copied = pixels
        return copied.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return nil }
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return context?.makeImage()
        }
    }

    private static func fallbackImage() -> CGImage {
        makeRGBCGImage(
            pixels: [0, 0, 0, 255],
            width: 1,
            height: 1,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )!
    }
}
