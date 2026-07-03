import AppKit
import Foundation
import UserNotifications

private actor RecognitionSerialQueue {
    private var latestWindow: (data: Data, sampleRate: Int)?
    private var worker: Task<Void, Never>?
    private(set) var skippedWindows: UInt64 = 0

    func enqueue(
        data: Data,
        sampleRate: Int,
        handler: @escaping @Sendable (Data, Int) async -> Void
    ) {
        if latestWindow != nil, worker != nil {
            skippedWindows += 1
        }
        latestWindow = (data, sampleRate)
        startWorkerIfNeeded(handler: handler)
    }

    func resetMetrics() {
        skippedWindows = 0
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        latestWindow = nil
    }

    private func startWorkerIfNeeded(handler: @escaping @Sendable (Data, Int) async -> Void) {
        guard worker == nil else { return }
        worker = Task {
            while !Task.isCancelled {
                guard let window = latestWindow else { break }
                latestWindow = nil
                await handler(window.data, window.sampleRate)
            }
            worker = nil
            if latestWindow != nil {
                startWorkerIfNeeded(handler: handler)
            }
        }
    }
}

@MainActor
final class BirdDetectionViewModel: ObservableObject {
    enum FileAnalysisState: Equatable {
        case idle
        case running(fileName: String, progress: Double, windowsProcessed: Int, detectionsFound: Int)
        case completed(fileName: String, windowsProcessed: Int, detectionsFound: Int)
        case failed(String)
    }

    @Published private(set) var detections: [BirdDetection] = []
    @Published private(set) var modelState: BirdNetCoreMLRecognizer.State = .stopped
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var statusMessage: String = "Starting…"
    @Published private(set) var species: [Bird] = []
    @Published private(set) var meterStats = AudioMeterStats()
    @Published private(set) var recognitionStats = RecognitionPipelineStats()
    @Published private(set) var fileAnalysisState: FileAnalysisState = .idle
    @Published private(set) var regionalLabel: String?
    @Published var showingEBirdForm = false
    @Published var selectedDetection: BirdDetection?
    @Published var selectedTab: MainWindowTab = .monitor

    enum MainWindowTab: Hashable {
        case monitor
        case offline
        case history
        case ignoreList
        case eBird
        case settings
    }

    private var openMainWindowHandler: (() -> Void)?

    let settings = AppSettings.shared
    let audioHandler = AudioHandler()
    let historyStore = RecognitionHistoryStore()
    let locationProvider = LocationProvider()

    private let recognizer = BirdNetCoreMLRecognizer()
    private var speciesCooldown = SpeciesCooldown()
    private var fileAnalysisCooldown = TimelineSpeciesCooldown()
    private var rateLimiter = NotificationRateLimiter()
    private var confidenceEstimator = ConfidenceRollingEstimator()
    private let recognitionQueue = RecognitionSerialQueue()
    private var runtimeTask: Task<Void, Never>?
    private var fileAnalysisTask: Task<Void, Never>?
    private var hasBootstrapped = false

    init() {
        Task { await bootstrapIfNeeded() }
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else {
            await refreshRuntime()
            return
        }
        hasBootstrapped = true

        LaunchAtLoginManager.sync(with: settings.launchAtLogin)
        settings.recordingEnabled = settings.startListeningAtLogin
        await recognizer.start()
        // Backpressure lives in RecognitionSerialQueue, which holds at most the
        // latest pending window. Gating enqueues on isCriticallyBehind here was
        // worse than useless: skippedWindows only ever grows, so after three
        // lifetime skips the gate started dropping windows forever.
        audioHandler.onWindowReady = { [weak self] data, sampleRate in
            guard let self else { return }
            Task { @MainActor in
                await self.recognitionQueue.enqueue(data: data, sampleRate: sampleRate) { data, sampleRate in
                    await self.performRecognition(data: data, sampleRate: sampleRate)
                }
            }
        }
        audioHandler.refreshPermissionStatus()
        audioHandler.setInputGain(dB: settings.inputGainDB)
        syncLocationAccess()
        await refreshRuntime()
        await loadSpeciesWhenReady()

        runtimeTask = Task {
            while !Task.isCancelled {
                await refreshRuntime()
                await refreshRegionalDataIfNeeded()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func shutdown() {
        runtimeTask?.cancel()
        runtimeTask = nil
        fileAnalysisTask?.cancel()
        fileAnalysisTask = nil
        Task { await recognitionQueue.cancel() }
        audioHandler.stop()
        historyStore.flush()
        Task { await recognizer.stop() }
    }

    func refreshRuntime() async {
        modelState = await recognizer.currentState()
        audioLevel = audioHandler.level
        meterStats = audioHandler.meterStats
        recognitionStats.silentWindowsSkipped = audioHandler.silentWindowsSkipped

        switch modelState {
        case .stopped:
            statusMessage = "Model stopped"
        case .loading:
            statusMessage = "Loading BirdNET…"
        case .ready:
            if audioHandler.isRunning {
                statusMessage = "Listening"
            } else if case .running = fileAnalysisState {
                break
            } else {
                statusMessage = "Ready"
            }
        case .failed(let message):
            statusMessage = message
        }
    }

    func reloadModel() {
        Task {
            await recognizer.stop()
            await recognizer.start()
            species = await recognizer.speciesCatalog()
            await refreshRuntime()
        }
    }

    var isListening: Bool {
        audioHandler.isRunning
    }

    var microphonePermissionGranted: Bool {
        audioHandler.permissionGranted
    }

    var canStartListening: Bool {
        guard modelState == .ready else { return false }
        guard !isListening else { return false }
        guard fileAnalysisTask == nil else { return false }
        return !audioHandler.isPermissionDenied
    }

    var canStopListening: Bool {
        isListening
    }

    var isAnalyzingFile: Bool {
        if case .running = fileAnalysisState { return true }
        return false
    }

    func applySuggestedConfidenceThreshold() {
        guard let suggested = recognitionStats.suggestedConfidenceThreshold else { return }
        let stepped = (suggested * 20).rounded() / 20
        settings.confidenceThreshold = stepped
    }

    func startListening() {
        settings.recordingEnabled = true
        Task {
            await recognitionQueue.resetMetrics()
            confidenceEstimator.reset()
            recognitionStats = RecognitionPipelineStats()
            await audioHandler.requestPermission()
            await startAudioIfPossible()
            await refreshRuntime()
        }
    }

    func stopListening() {
        settings.recordingEnabled = false
        audioHandler.stop()
        Task { await refreshRuntime() }
    }

    func analyzeAudioFile(at url: URL) {
        fileAnalysisTask?.cancel()
        stopListening()

        let fileName = url.lastPathComponent
        fileAnalysisCooldown.reset()
        fileAnalysisState = .running(fileName: fileName, progress: 0, windowsProcessed: 0, detectionsFound: 0)

        fileAnalysisTask = Task {
            do {
                let samples = try AudioFileLoader.loadSamples(from: url)
                let hopSamples = AudioFileLoader.windowSamples / 2
                let windows = AudioFileLoader.windows(from: samples, hopSamples: hopSamples)
                guard !windows.isEmpty else {
                    fileAnalysisState = .failed("Audio file is empty.")
                    fileAnalysisTask = nil
                    await refreshRuntime()
                    return
                }

                var detectionsFound = 0
                for (index, window) in windows.enumerated() {
                    try Task.checkCancellation()
                    let pcmData = AudioFileLoader.pcmData(from: window)
                    let offsetSeconds = AudioFileLoader.offsetSeconds(forWindowIndex: index, hopSamples: hopSamples)
                    if await performRecognition(
                        data: pcmData,
                        sampleRate: AudioFileLoader.modelSampleRate,
                        source: .file,
                        sourceFileName: fileName,
                        audioOffsetSeconds: offsetSeconds,
                        notify: true
                    ) {
                        detectionsFound += 1
                    }

                    let progress = Double(index + 1) / Double(windows.count)
                    fileAnalysisState = .running(
                        fileName: fileName,
                        progress: progress,
                        windowsProcessed: index + 1,
                        detectionsFound: detectionsFound
                    )
                }

                fileAnalysisState = .completed(
                    fileName: fileName,
                    windowsProcessed: windows.count,
                    detectionsFound: detectionsFound
                )
            } catch is CancellationError {
                fileAnalysisState = .idle
            } catch {
                fileAnalysisState = .failed(error.localizedDescription)
            }

            fileAnalysisTask = nil
            await refreshRuntime()
        }
    }

    func syncLocationAccess() {
        if settings.locationFilteringEnabled {
            locationProvider.request()
            Task { await refreshRegionalDataIfNeeded() }
        } else {
            locationProvider.stop()
            regionalLabel = nil
        }
    }

    func cancelFileAnalysis() {
        fileAnalysisTask?.cancel()
        fileAnalysisTask = nil
        fileAnalysisState = .idle
        Task { await refreshRuntime() }
    }

    func reconfigureSpectrogram() {
        audioHandler.reconfigureSpectrogram(settings: settings)
    }

    /// Restart capture so hop-size changes take effect; no-op when idle.
    func applyDetectionPipelineSettings() {
        guard isListening else { return }
        Task {
            audioHandler.stop()
            await startAudioIfPossible()
            await refreshRuntime()
        }
    }

    func applySilenceGate() {
        audioHandler.setSilenceGate(
            enabled: settings.silenceSkipEnabled,
            thresholdDB: settings.silenceSkipThresholdDB
        )
    }

    func bindOpenMainWindow(_ handler: @escaping () -> Void) {
        openMainWindowHandler = handler
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindowHandler?()
    }

    func submitToEBird(for detection: BirdDetection) {
        selectedTab = .eBird
        openMainWindow()
    }

    func submitToEBirdSheet(for detection: BirdDetection) {
        selectedDetection = detection
        showingEBirdForm = true
    }

    func deleteDetection(_ detection: BirdDetection) {
        detections.removeAll { $0.id == detection.id }
        historyStore.remove(id: detection.id)
        if selectedDetection?.id == detection.id {
            selectedDetection = nil
        }
    }

    func clearRecentDetections() {
        detections.removeAll()
        settings.recentClearedAt = Date()
        selectedDetection = nil
    }

    var sessionSpecies: [SessionSpeciesSummary] {
        historyStore.uniqueSpecies(since: settings.recentClearedAt)
    }

    func ignore(detection: BirdDetection) {
        settings.ignore(detection: detection)
        objectWillChange.send()
    }

    func isIgnored(_ detection: BirdDetection) -> Bool {
        settings.isIgnored(detection: detection)
    }

    func reloadSpeciesIfNeeded() async {
        guard species.isEmpty else { return }
        guard await recognizer.currentState() == .ready else { return }
        species = await recognizer.speciesCatalog()
    }

    private func startAudioIfPossible() async {
        guard settings.recordingEnabled else {
            audioHandler.stop()
            statusMessage = "Recording paused"
            return
        }
        guard modelState == .ready else { return }
        guard audioHandler.permissionGranted else {
            statusMessage = "Microphone access required"
            return
        }
        do {
            try audioHandler.start(settings: settings)
            statusMessage = "Listening"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadSpeciesWhenReady() async {
        for _ in 0..<30 {
            let state = await recognizer.currentState()
            modelState = state
            guard state == .ready else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            species = await recognizer.speciesCatalog()
            return
        }
    }

    private func refreshRegionalDataIfNeeded() async {
        guard settings.locationFilteringEnabled else { return }
        guard let location = locationProvider.lastKnownLocation else { return }
        await EBirdRegionalService.shared.refreshIfNeeded(
            location: location,
            apiKey: settings.resolvedEBirdApiKey
        )
        regionalLabel = await EBirdRegionalService.shared.currentRegionLabel()
    }

    @discardableResult
    private func performRecognition(
        data: Data,
        sampleRate: Int,
        source: DetectionSource = .live,
        sourceFileName: String? = nil,
        audioOffsetSeconds: Double? = nil,
        notify: Bool = true
    ) async -> Bool {
        guard await recognizer.currentState() == .ready else { return false }
        recognitionStats.isInFlight = true

        defer {
            recognitionStats.isInFlight = false
            recognitionStats.lastCompletedAt = Date()
        }

        do {
            let result = try await recognizer.recognize(
                pcmData: data,
                sampleRate: sampleRate,
                applyAutoGain: settings.autoGainEnabled
            )
            recognitionStats.lastInferenceMs = result.inferenceMs
            recognitionStats.lastAutoGainDB = result.autoGainDB > 0.1 ? result.autoGainDB : nil

            let topConfidence = result.detections.map(\.confidence).max() ?? 0
            confidenceEstimator.record(confidence: topConfidence)
            recognitionStats.rollingAverageTopConfidence = confidenceEstimator.rollingAverageTopConfidence
            recognitionStats.suggestedConfidenceThreshold = confidenceEstimator.suggestedThreshold

            if result.detections.isEmpty {
                RecognitionLogger.log("recognize (no match) \(result.inferenceMs)ms")
            } else {
                for response in result.detections {
                    RecognitionLogger.log(
                        "recognize \(response.bird) (\(response.scientificName)) " +
                        "conf=\(String(format: "%.3f", response.confidence)) \(result.inferenceMs)ms" +
                        (source == .file ? " file=\(sourceFileName ?? "") offset=\(audioOffsetSeconds ?? 0)s" : "")
                    )
                }
            }

            if result.detections.isEmpty || topConfidence < settings.confidenceThreshold {
                recognitionStats.belowThresholdCount += 1
            }

            var recordedAny = false
            for response in result.detections {
                if await handleRecognition(
                    response,
                    source: source,
                    sourceFileName: sourceFileName,
                    audioOffsetSeconds: audioOffsetSeconds,
                    notify: notify
                ) {
                    recordedAny = true
                }
            }
            recognitionStats.skippedWindows = await recognitionQueue.skippedWindows
            return recordedAny
        } catch {
            if Task.isCancelled { return false }
            statusMessage = error.localizedDescription
            recognitionStats.skippedWindows = await recognitionQueue.skippedWindows
            return false
        }
    }

    @discardableResult
    private func handleRecognition(
        _ response: RecognitionResponse,
        source: DetectionSource = .live,
        sourceFileName: String? = nil,
        audioOffsetSeconds: Double? = nil,
        notify: Bool = true
    ) async -> Bool {
        let ignoreList = IgnoreList(
            speciesIDs: settings.ignoredSpeciesIDs,
            speciesNames: settings.ignoredSpeciesNames
        )
        guard response.confidence >= settings.confidenceThreshold else {
            return false
        }
        if ignoreList.isSpeciesIgnored(birdId: response.id, birdName: response.bird) {
            settings.recordSuppressed(birdName: response.bird)
            return false
        }

        let rarity = await lookupRarity(scientificName: response.scientificName)

        if settings.locationFilteringEnabled,
           let rarity,
           rarity.level == .unusual,
           response.confidence < settings.confidenceThreshold + 0.1 {
            RecognitionLogger.log(
                "suppressed unusual species below boosted threshold: \(response.bird) " +
                "conf=\(String(format: "%.3f", response.confidence))"
            )
            return false
        }

        if source == .file {
            let offset = audioOffsetSeconds ?? 0
            guard fileAnalysisCooldown.shouldAllow(speciesId: response.id, now: offset) else {
                return false
            }
        }

        let detection = BirdDetection(
            birdName: response.bird,
            scientificName: response.scientificName,
            confidence: response.confidence,
            birdId: response.id,
            inferenceMs: response.timeMs,
            source: source,
            sourceFileName: sourceFileName,
            audioOffsetSeconds: audioOffsetSeconds,
            rarity: rarity
        )
        recordDetection(detection)

        if source == .file {
            fileAnalysisCooldown.markQualified(
                speciesId: response.id,
                cooldownSeconds: settings.perSpeciesCooldownSeconds,
                now: audioOffsetSeconds ?? 0
            )
        }

        var shouldNotify = notify
        if shouldNotify {
            if source == .file {
                shouldNotify = rateLimiter.shouldAllow(maxPerHour: settings.maxNotificationsPerHour)
            } else {
                shouldNotify = speciesCooldown.shouldAllow(speciesId: response.id)
                    && rateLimiter.shouldAllow(maxPerHour: settings.maxNotificationsPerHour)
            }
        }
        if shouldNotify {
            if source != .file {
                speciesCooldown.markNotified(
                    speciesId: response.id,
                    cooldownSeconds: settings.perSpeciesCooldownSeconds
                )
            }
            rateLimiter.markNotified()
            if settings.notificationsEnabled {
                await sendNotification(for: detection)
            }
        }

        return true
    }

    private func lookupRarity(scientificName: String) async -> RarityInfo? {
        guard settings.locationFilteringEnabled else { return nil }
        return await EBirdRegionalService.shared.rarity(
            for: scientificName,
            apiKey: settings.resolvedEBirdApiKey
        )
    }

    private func recordDetection(_ detection: BirdDetection) {
        detections.insert(detection, at: 0)
        if detections.count > 50 {
            detections = Array(detections.prefix(50))
        }
        historyStore.append(detection)
    }

    private func sendNotification(for detection: BirdDetection) async {
        let center = UNUserNotificationCenter.current()
        let systemSettings = await center.notificationSettings()
        var granted = systemSettings.authorizationStatus == .authorized || systemSettings.authorizationStatus == .provisional
        if !granted && systemSettings.authorizationStatus == .notDetermined {
            granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "🐦 \(detection.birdName)"
        content.subtitle = detection.scientificName
        var body = String(format: "Confidence %.0f%%", detection.confidence * 100)
        if let rarity = detection.rarity, rarity.level == .unusual {
            body += " · Unusual for your area"
        }
        content.body = body
        if settings.notificationSoundEnabled {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: detection.id.uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            // Authorization can succeed while delivery still fails for agent apps.
        }
    }
}
