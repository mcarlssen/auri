import AVFoundation
import Accelerate
import Foundation

private func AudioLog(_ message: @autoclosure () -> String) {
    if UserDefaults.standard.bool(forKey: "debugLogging") {
        print("[Audio] \(message())")
    }
}

private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}

final class AudioHandler: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0
    @Published private(set) var meterStats = AudioMeterStats()
    @Published private(set) var spectrogram: SpectrogramEngine.Snapshot?
    @Published private(set) var permissionGranted = false
    @Published private(set) var lastError: String?

    var onWindowReady: ((Data, Int) -> Void)?
    var onSpectrogramSnapshot: ((SpectrogramEngine.Snapshot) -> Void)?

    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let captureDelegate = AudioCaptureDelegate()
    private let captureQueue = DispatchQueue(label: "com.x38.auri.capture")
    private let processingQueue = DispatchQueue(
        label: "com.x38.auri.audio-processing",
        qos: .userInitiated
    )
    private let spectrogramQueue = DispatchQueue(label: "com.x38.auri.spectrogram")
    private var spectrogramEngine: SpectrogramEngine
    private var spectrogramConfiguration: SpectrogramConfiguration?

    private var converter: AVAudioConverter?
    private var converterInputKey: ConverterInputKey?
    private var targetFormat: AVAudioFormat?
    private static let birdNetWindowSampleCount = BirdNetCoreMLRecognizer.windowSamples
    private var windowAccumulator = WindowAccumulator(
        windowSampleCount: birdNetWindowSampleCount,
        hopByteCount: (birdNetWindowSampleCount / 2) * MemoryLayout<Float>.size
    )
    private var lastPublishedSilentSkipCount: UInt64 = 0
    @Published private(set) var silentWindowsSkipped: UInt64 = 0
    private var bufferCount: UInt64 = 0
    private var lastBufferReceivedAt = Date.distantPast
    private var lastSpectrogramPublish = Date.distantPast
    private var hasPublishedSpectrogram = false
    private var lastPublishedColumnGeneration: UInt64 = 0
    private var spectrogramNeedsSnapshot = false
    private var spectrogramPendingSamples: [Float] = []
    private var spectrogramDrainInFlight = false
    // Guarded by spectrogramLock. While no view displays the spectrogram
    // (menu bar apps run headless most of the time), skip the FFT/render
    // pipeline entirely.
    private var spectrogramDisplayActive = false
    private var spectrogramObserverCount = 0
    private var spectrogramPublishTimer: DispatchSourceTimer?
    private let spectrogramLock = NSLock()
    private let maxPendingSamples = BirdNetCoreMLRecognizer.modelSampleRate * 2
    private var lastStatsPublish = Date.distantPast
    private var inputGainLinear: Float = 1
    private var activeCaptureKey: CaptureKey?
    private var processingBacklog = 0
    private let maxProcessingBacklog = 6
    private let processingBacklogLock = NSLock()
    private var loggedPassthrough = false

    private struct CaptureKey: Equatable {
        let deviceUID: String
        let inputSource: AudioInputSource
    }

    init() {
        spectrogramEngine = SpectrogramEngine(configuration: .default)
    }

    @MainActor
    func reconfigureSpectrogram(settings: AppSettings) {
        let configuration = SpectrogramConfiguration.displayMonitor(settings: settings)
        guard configuration != spectrogramConfiguration else { return }
        let rebuildAnalysis = configuration.requiresAnalysisRebuild(comparedTo: spectrogramConfiguration)
        spectrogramConfiguration = configuration
        spectrogram = nil

        spectrogramQueue.sync { [weak self] in
            guard let self else { return }
            self.spectrogramLock.lock()
            self.spectrogramPendingSamples.removeAll(keepingCapacity: false)
            self.spectrogramLock.unlock()
            self.resetSpectrogramPublishState()
            if rebuildAnalysis {
                self.spectrogramEngine = SpectrogramEngine(configuration: configuration)
            } else {
                self.spectrogramEngine.applyDisplayConfiguration(configuration)
            }
            if self.isRunning {
                self.publishSpectrogramSnapshot()
            }
        }
    }

    private func initializeSpectrogramEngine(
        configuration: SpectrogramConfiguration,
        rebuildAnalysis: Bool
    ) {
        spectrogramQueue.sync { [weak self] in
            guard let self else { return }
            self.spectrogramLock.lock()
            self.spectrogramPendingSamples.removeAll(keepingCapacity: false)
            self.spectrogramLock.unlock()
            self.resetSpectrogramPublishState()
            if rebuildAnalysis {
                self.spectrogramEngine = SpectrogramEngine(configuration: configuration)
            } else {
                self.spectrogramEngine.resetBuffer()
            }
        }
    }

    private func resetSpectrogramPublishState() {
        spectrogramNeedsSnapshot = false
        hasPublishedSpectrogram = false
        lastPublishedColumnGeneration = 0
    }

    private struct ConverterInputKey: Equatable {
        let sampleRate: Double
        let channels: AVAudioChannelCount
        let isInterleaved: Bool
        let commonFormat: AVAudioCommonFormat
    }

    @MainActor
    func refreshPermissionStatus() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permissionGranted = true
        case .denied:
            permissionGranted = false
            lastError = "Microphone access denied. Enable it in System Settings."
        case .undetermined:
            permissionGranted = false
            lastError = nil
        @unknown default:
            permissionGranted = false
        }
    }

    var isPermissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    @MainActor
    func requestPermission() async {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permissionGranted = true
            lastError = nil
        case .denied:
            permissionGranted = false
            lastError = "Microphone access denied. Enable it in System Settings."
        case .undetermined:
            permissionGranted = await AVAudioApplication.requestRecordPermission()
            if !permissionGranted {
                lastError = "Microphone access denied. Enable it in System Settings."
            }
        @unknown default:
            permissionGranted = false
        }
    }

    @MainActor
    func setInputGain(dB: Double) {
        inputGainLinear = Float(pow(10, dB / 20))
    }

    @MainActor
    func setSilenceGate(enabled: Bool, thresholdDB: Double) {
        windowAccumulator.silenceGateEnabled = enabled
        windowAccumulator.silenceGateThresholdLinear = Float(pow(10, thresholdDB / 20))
    }

    /// Views displaying the spectrogram register here; the FFT/render pipeline
    /// only runs while at least one observer is visible.
    @MainActor
    func setSpectrogramVisible(_ visible: Bool) {
        spectrogramLock.lock()
        spectrogramObserverCount = max(0, spectrogramObserverCount + (visible ? 1 : -1))
        let active = spectrogramObserverCount > 0
        let becameActive = active && !spectrogramDisplayActive
        spectrogramDisplayActive = active
        if !active {
            spectrogramPendingSamples.removeAll(keepingCapacity: false)
        }
        spectrogramLock.unlock()

        if becameActive {
            // Old columns are stale after a gap; restart the scroll from blank.
            spectrogramQueue.async { [weak self] in
                guard let self else { return }
                self.spectrogramEngine.resetBuffer()
                self.resetSpectrogramPublishState()
            }
        }
    }

    @MainActor
    func start(settings: AppSettings) throws {
        AudioLog("Starting audio with recordingEnabled=\(settings.recordingEnabled)")
        guard settings.recordingEnabled else {
            stop()
            return
        }
        guard permissionGranted else {
            throw AudioHandlerError.permissionDenied
        }

        setInputGain(dB: settings.inputGainDB)

        guard let device = selectedDevice(settings: settings) else {
            throw AudioHandlerError.noInputDevice
        }

        let captureKey = CaptureKey(deviceUID: device.uniqueID, inputSource: settings.audioInputSource)
        if isRunning, activeCaptureKey == captureKey {
            AudioLog("Already capturing from \(device.localizedName); skipping restart")
            return
        }

        stop()

        let configuration = SpectrogramConfiguration.displayMonitor(settings: settings)
        let rebuildAnalysis = configuration.requiresAnalysisRebuild(comparedTo: spectrogramConfiguration)
        spectrogramConfiguration = configuration
        initializeSpectrogramEngine(configuration: configuration, rebuildAnalysis: rebuildAnalysis)

        activeCaptureKey = captureKey
        AudioLog("Selected device: \(device.localizedName) (uid=\(device.uniqueID))")

        session.beginConfiguration()

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        // Do not set audioOutput.audioSettings — that forces CMIO's internal converter
        // and triggers RebuildAudioConverter failures on many devices.

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioHandlerError.noInputDevice
        }
        session.addInput(input)

        guard session.canAddOutput(audioOutput) else {
            session.commitConfiguration()
            throw AudioHandlerError.formatUnavailable
        }
        session.addOutput(audioOutput)
        session.commitConfiguration()

        if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription),
           let format = AVAudioFormat(streamDescription: streamDescription) {
            AudioLog("Device active format sampleRate=\(format.sampleRate), channels=\(format.channelCount), interleaved=\(format.isInterleaved)")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(BirdNetCoreMLRecognizer.modelSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioHandlerError.formatUnavailable
        }

        self.targetFormat = targetFormat
        converter = nil
        converterInputKey = nil
        windowAccumulator.reset(keepingCapacity: true)
        bufferCount = 0
        loggedPassthrough = false
        windowAccumulator.hopByteCount = settings.detectionOverlap.hopSamples(
            windowSamples: Self.birdNetWindowSampleCount
        ) * MemoryLayout<Float>.size
        setSilenceGate(enabled: settings.silenceSkipEnabled, thresholdDB: settings.silenceSkipThresholdDB)
        windowAccumulator.resetSilentCount()
        lastPublishedSilentSkipCount = 0
        silentWindowsSkipped = 0
        AudioLog("Target format sr=\(Int(targetFormat.sampleRate)) ch=\(Int(targetFormat.channelCount))")

        captureDelegate.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self else { return }
            // Count queued buffers at enqueue time, on the capture callback. The
            // processing queue is serial, so counting inside the work item can
            // never observe a backlog above 1 — if processing falls behind, the
            // queue would retain an unbounded pile of CMSampleBuffers instead of
            // shedding load.
            self.processingBacklogLock.lock()
            guard self.processingBacklog < self.maxProcessingBacklog else {
                self.processingBacklogLock.unlock()
                return
            }
            self.processingBacklog += 1
            self.processingBacklogLock.unlock()
            self.processingQueue.async {
                defer {
                    self.processingBacklogLock.lock()
                    self.processingBacklog -= 1
                    self.processingBacklogLock.unlock()
                }
                // The queue never goes idle while listening, so its implicit
                // autorelease pool rarely drains; the PCM buffers and converter
                // scratch allocated per callback need an explicit pool.
                autoreleasepool {
                    self.handle(sampleBuffer: sampleBuffer)
                }
            }
        }
        audioOutput.setSampleBufferDelegate(captureDelegate, queue: captureQueue)

        session.startRunning()
        isRunning = session.isRunning
        lastError = isRunning ? nil : "Unable to start audio capture."
        if !isRunning {
            throw AudioHandlerError.formatUnavailable
        }
        startSpectrogramPublishTimer()
    }

    @MainActor
    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        captureDelegate.onSampleBuffer = nil
        converter = nil
        converterInputKey = nil
        isRunning = false
        activeCaptureKey = nil
        level = 0
        meterStats = AudioMeterStats()
        spectrogram = nil
        stopSpectrogramPublishTimer()
        spectrogramQueue.sync { [weak self] in
            guard let self else { return }
            self.spectrogramPendingSamples.removeAll(keepingCapacity: false)
            self.resetSpectrogramPublishState()
        }
        bufferCount = 0
    }

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    @MainActor
    private func selectedDevice(settings: AppSettings) -> AVCaptureDevice? {
        let devices = Self.availableDevices()
        switch settings.audioInputSource {
        case .defaultMic:
            return devices.first
        case .blackhole:
            return devices.first { $0.localizedName.localizedCaseInsensitiveContains("BlackHole") } ?? devices.first
        case .selectedDevice:
            return devices.first { $0.uniqueID == settings.selectedDeviceUID } ?? devices.first
        }
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        guard let targetFormat else { return }
        guard let pcmBuffer = makePCMBuffer(from: sampleBuffer) else {
            AudioLog("makePCMBuffer failed")
            return
        }

        bufferCount += 1
        lastBufferReceivedAt = Date()

        guard var monoBuffer = makeMonoSamples(from: pcmBuffer, targetFormat: targetFormat) else {
            AudioLog("Failed to produce mono samples")
            return
        }
        guard !monoBuffer.isEmpty else { return }

        applyInputGain(to: &monoBuffer)

        publishStats(from: monoBuffer)
        submitSpectrogramSamples(monoBuffer)

        let chunk = monoBuffer.withUnsafeBufferPointer { Data(buffer: $0) }
        windowAccumulator.append(chunk)

        while let window = windowAccumulator.nextWindow() {
            onWindowReady?(window, BirdNetCoreMLRecognizer.modelSampleRate)
        }

        let skipped = windowAccumulator.silentWindowsSkipped
        if skipped != lastPublishedSilentSkipCount {
            lastPublishedSilentSkipCount = skipped
            Task { @MainActor in self.silentWindowsSkipped = skipped }
        }
    }

    private func applyInputGain(to samples: inout [Float]) {
        guard inputGainLinear != 1 else { return }
        var gain = inputGainLinear
        vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))

        // Peak-safe: if the user gain pushed any sample past ±1, scale the whole
        // buffer back down so the max magnitude is exactly 1.0. This preserves the
        // waveform shape instead of hard-clipping, which distorts the model input.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 1 else { return }
        var scale = 1 / peak
        vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(samples.count))
    }

    private func publishStats(from samples: [Float]) {
        let now = Date()
        let isReceiving = now.timeIntervalSince(lastBufferReceivedAt) < 2

        if now.timeIntervalSince(lastStatsPublish) >= 1.0 / 15.0 {
            lastStatsPublish = now
            let stats = AudioMeterStats.from(
                samples: samples,
                buffersReceived: bufferCount,
                isReceiving: isReceiving
            )
            Task { @MainActor in
                self.level = min(1, stats.rms * 12)
                self.meterStats = stats
            }
        }
    }

    private func submitSpectrogramSamples(_ samples: [Float]) {
        spectrogramLock.lock()
        guard spectrogramDisplayActive else {
            spectrogramLock.unlock()
            return
        }
        spectrogramPendingSamples.append(contentsOf: samples)
        if spectrogramPendingSamples.count > maxPendingSamples {
            spectrogramPendingSamples.removeFirst(spectrogramPendingSamples.count - maxPendingSamples)
        }
        let shouldSchedule = !spectrogramDrainInFlight
        if shouldSchedule {
            spectrogramDrainInFlight = true
        }
        spectrogramLock.unlock()

        guard shouldSchedule else { return }
        spectrogramQueue.async { [weak self] in
            self?.runSpectrogramDrain()
        }
    }

    private func finishSpectrogramDrain() {
        spectrogramLock.lock()
        spectrogramDrainInFlight = false
        let hasPending = !spectrogramPendingSamples.isEmpty
        spectrogramLock.unlock()
        if hasPending {
            submitSpectrogramSamples([])
        }
    }

    private func runSpectrogramDrain() {
        defer { finishSpectrogramDrain() }
        while true {
            spectrogramLock.lock()
            guard !spectrogramPendingSamples.isEmpty else {
                spectrogramLock.unlock()
                break
            }
            let batch = spectrogramPendingSamples
            spectrogramPendingSamples.removeAll(keepingCapacity: true)
            spectrogramLock.unlock()

            spectrogramEngine.discardBacklogIfBehind()
            let columnsWritten = spectrogramEngine.ingest(samples: batch)
            if columnsWritten > 0 {
                spectrogramNeedsSnapshot = true
                // AudioLog("Spectrogram wrote \(columnsWritten) column(s), filled=\(spectrogramEngine.filledColumnCount)")
            }

            spectrogramLock.lock()
            let morePending = !spectrogramPendingSamples.isEmpty
            spectrogramLock.unlock()
            if !morePending {
                break
            }
        }

        publishSpectrogramSnapshotIfNeeded()
    }

    private func publishSpectrogramSnapshotIfNeeded() {
        guard spectrogramNeedsSnapshot else { return }
        let now = Date()
        let shouldThrottle = hasPublishedSpectrogram
            && now.timeIntervalSince(lastSpectrogramPublish) < 1.0 / 60.0
        if shouldThrottle {
            let delay = max(0.001, (1.0 / 60.0) - now.timeIntervalSince(lastSpectrogramPublish))
            spectrogramQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.publishSpectrogramSnapshotIfNeeded()
            }
            return
        }
        publishSpectrogramSnapshot()
    }

    private func publishSpectrogramSnapshot() {
        let generation = spectrogramEngine.columnGeneration
        guard generation > lastPublishedColumnGeneration || !hasPublishedSpectrogram else {
            return
        }

        lastSpectrogramPublish = Date()
        hasPublishedSpectrogram = true
        lastPublishedColumnGeneration = generation
        spectrogramNeedsSnapshot = false
        let snapshot = spectrogramEngine.makeSnapshot()
        // AudioLog(
        //     "Spectrogram publish gen=\(generation) filled=\(spectrogramEngine.filledColumnCount) version=\(snapshot.version)"
        // )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spectrogram = snapshot
            self.onSpectrogramSnapshot?(snapshot)
        }

        spectrogramLock.lock()
        let hasPending = !spectrogramPendingSamples.isEmpty
        spectrogramLock.unlock()
        if hasPending {
            submitSpectrogramSamples([])
        }
    }

    private func startSpectrogramPublishTimer() {
        spectrogramQueue.async { [weak self] in
            guard let self else { return }
            self.spectrogramPublishTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.spectrogramQueue)
            timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard self.spectrogramEngine.columnGeneration > self.lastPublishedColumnGeneration else { return }
                self.spectrogramNeedsSnapshot = true
                self.publishSpectrogramSnapshotIfNeeded()
            }
            timer.resume()
            self.spectrogramPublishTimer = timer
        }
    }

    private func stopSpectrogramPublishTimer() {
        spectrogramQueue.async { [weak self] in
            self?.spectrogramPublishTimer?.cancel()
            self?.spectrogramPublishTimer = nil
        }
    }

    private func makeMonoSamples(from pcmBuffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> [Float]? {
        if canPassthrough(pcmBuffer, to: targetFormat),
           let direct = extractMonoFloatSamples(from: pcmBuffer) {
            if !loggedPassthrough {
                loggedPassthrough = true
                AudioLog("Using direct PCM passthrough (no converter)")
            }
            return direct
        }

        let inputKey = ConverterInputKey(
            sampleRate: pcmBuffer.format.sampleRate,
            channels: pcmBuffer.format.channelCount,
            isInterleaved: pcmBuffer.format.isInterleaved,
            commonFormat: pcmBuffer.format.commonFormat
        )

        if converter == nil || converterInputKey != inputKey {
            AudioLog("Configuring converter from sr=\(Int(pcmBuffer.format.sampleRate)) ch=\(Int(pcmBuffer.format.channelCount)) interleaved=\(pcmBuffer.format.isInterleaved)")
            converter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
            converterInputKey = inputKey
            if converter == nil {
                AudioLog("Failed to create AVAudioConverter")
                return nil
            }
        }
        guard let converter else { return nil }

        let frameCapacity = AVAudioFrameCount(
            ceil(Double(pcmBuffer.frameLength) * targetFormat.sampleRate / pcmBuffer.format.sampleRate)
        )
        guard frameCapacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var error: NSError?
        var consumedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        if let error {
            AudioLog("Convert error: \(error.code) domain=\(error.domain)")
            return nil
        }

        return extractMonoFloatSamples(from: converted)
    }

    private func canPassthrough(_ input: AVAudioPCMBuffer, to output: AVAudioFormat) -> Bool {
        input.format.sampleRate == output.sampleRate
            && input.format.channelCount == 1
            && output.channelCount == 1
            && input.format.commonFormat == .pcmFormatFloat32
    }

    private func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        // floatChannelData is undefined for interleaved buffers; read AudioBufferList instead.
        if buffer.format.isInterleaved {
            return extractInterleavedMonoSamples(from: buffer, frames: frames)
        }

        guard let channelData = buffer.floatChannelData else { return nil }

        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        }

        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            vDSP_vadd(mono, 1, channelData[channel], 1, &mono, 1, vDSP_Length(frames))
        }
        var scale = Float(1.0 / Float(channels))
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
        return mono
    }

    private func extractInterleavedMonoSamples(from buffer: AVAudioPCMBuffer, frames: Int) -> [Float]? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return nil }

        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return nil }
        let ptr = mData.assumingMemoryBound(to: Float.self)

        if channels == 1 {
            return Array(UnsafeBufferPointer(start: ptr, count: frames))
        }

        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            vDSP_vadd(mono, 1, ptr.advanced(by: channel), vDSP_Stride(channels), &mono, 1, vDSP_Length(frames))
        }
        var scale = Float(1.0 / Float(channels))
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
        return mono
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }
        return buffer
    }
}

enum AudioHandlerError: LocalizedError {
    case permissionDenied
    case formatUnavailable
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission is required."
        case .formatUnavailable: return "Unable to configure audio format."
        case .noInputDevice: return "No audio input device is available."
        }
    }
}
