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
    @Published private(set) var detections: [BirdDetection] = []
    @Published private(set) var modelState: BirdNetCoreMLRecognizer.State = .stopped
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var statusMessage: String = "Starting…"
    @Published private(set) var species: [Bird] = []
    @Published private(set) var meterStats = AudioMeterStats()
    @Published private(set) var recognitionStats = RecognitionPipelineStats()
    @Published var showingEBirdForm = false
    @Published var selectedDetection: BirdDetection?
    @Published var selectedTab: MainWindowTab = .monitor

    enum MainWindowTab: Hashable {
        case monitor
        case ignoreList
        case eBird
        case settings
    }

    private var openMainWindowHandler: (() -> Void)?

    let settings = AppSettings.shared
    let audioHandler = AudioHandler()

    private let recognizer = BirdNetCoreMLRecognizer()
    private var cooldown = Cooldown()
    private var rateLimiter = NotificationRateLimiter()
    private let recognitionQueue = RecognitionSerialQueue()
    private var runtimeTask: Task<Void, Never>?
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
        audioHandler.onWindowReady = { [weak self] data, sampleRate in
            guard let self else { return }
            Task { @MainActor in
                if self.recognitionStats.isCriticallyBehind, self.recognitionStats.isInFlight {
                    return
                }
                await self.recognitionQueue.enqueue(data: data, sampleRate: sampleRate) { data, sampleRate in
                    await self.performRecognition(data: data, sampleRate: sampleRate)
                }
            }
        }
        audioHandler.refreshPermissionStatus()
        audioHandler.setInputGain(dB: settings.inputGainDB)
        await refreshRuntime()
        await loadSpeciesWhenReady()

        runtimeTask = Task {
            while !Task.isCancelled {
                await refreshRuntime()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func shutdown() {
        runtimeTask?.cancel()
        runtimeTask = nil
        Task { await recognitionQueue.cancel() }
        audioHandler.stop()
        Task { await recognizer.stop() }
    }

    func refreshRuntime() async {
        modelState = await recognizer.currentState()
        audioLevel = audioHandler.level
        meterStats = audioHandler.meterStats

        switch modelState {
        case .stopped:
            statusMessage = "Model stopped"
        case .loading:
            statusMessage = "Loading BirdNET…"
        case .ready:
            if audioHandler.isRunning {
                statusMessage = "Listening"
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
        return !audioHandler.isPermissionDenied
    }

    var canStopListening: Bool {
        isListening
    }

    func startListening() {
        settings.recordingEnabled = true
        Task {
            await recognitionQueue.resetMetrics()
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

    func reconfigureSpectrogram() {
        audioHandler.reconfigureSpectrogram(settings: settings)
    }

    func bindOpenMainWindow(_ handler: @escaping () -> Void) {
        openMainWindowHandler = handler
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindowHandler?()
    }

    func submitToEBird(for detection: BirdDetection) {
        selectedDetection = detection
        selectedTab = .eBird
        openMainWindow()
    }

    func submitToEBirdSheet(for detection: BirdDetection) {
        selectedDetection = detection
        showingEBirdForm = true
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

    /// Inserts a fake detection for UI/notification testing. Bypasses threshold, ignore list, and cooldown.
    func injectTestDetection() {
        let samples: [(name: String, scientific: String, id: Int)] = [
            ("American Robin", "Turdus migratorius", 10_001),
            ("Northern Cardinal", "Cardinalis cardinalis", 10_002),
            ("Blue Jay", "Cyanocitta cristata", 10_003),
            ("Black-capped Chickadee", "Poecile atricapillus", 10_004),
            ("Mourning Dove", "Zenaida macroura", 10_005),
        ]
        let sample = samples.randomElement() ?? samples[0]
        let detection = BirdDetection(
            birdName: sample.name,
            scientificName: sample.scientific,
            confidence: Double.random(in: 0.72...0.95),
            birdId: sample.id,
            inferenceMs: Int.random(in: 80...250)
        )
        detections.insert(detection, at: 0)
        if detections.count > 50 {
            detections = Array(detections.prefix(50))
        }
        if settings.notificationsEnabled {
            Task { await sendNotification(for: detection) }
        }
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

    private func performRecognition(data: Data, sampleRate: Int) async {
        guard await recognizer.currentState() == .ready else { return }
        recognitionStats.isInFlight = true
        do {
            let result = try await recognizer.recognize(pcmData: data, sampleRate: sampleRate)
            recognitionStats.lastInferenceMs = result.inferenceMs
            if settings.debugLogging, let response = result.detection {
                print(
                    "[BirdNet] recognize \(response.bird) (\(response.scientificName)) " +
                    "conf=\(String(format: "%.3f", response.confidence)) \(result.inferenceMs)ms"
                )
            } else if settings.debugLogging {
                print("[BirdNet] recognize (no match) \(result.inferenceMs)ms")
            }
            guard let response = result.detection else { return }
            await handleRecognition(response)
        } catch {
            if Task.isCancelled { return }
            statusMessage = error.localizedDescription
        }
        recognitionStats.isInFlight = false
        recognitionStats.lastCompletedAt = Date()
        recognitionStats.skippedWindows = await recognitionQueue.skippedWindows
    }

    private func handleRecognition(_ response: RecognitionResponse) async {
        let ignoreList = IgnoreList(
            speciesIDs: settings.ignoredSpeciesIDs,
            speciesNames: settings.ignoredSpeciesNames
        )
        guard response.confidence >= settings.confidenceThreshold else {
            var stats = recognitionStats
            stats.belowThresholdCount += 1
            recognitionStats = stats
            return
        }
        if ignoreList.isSpeciesIgnored(birdId: response.id, birdName: response.bird) {
            settings.recordSuppressed(birdName: response.bird)
            return
        }
        guard cooldown.shouldAllow(baseDelay: settings.cooldownSeconds) else { return }
        guard rateLimiter.shouldAllow(maxPerHour: settings.maxNotificationsPerHour) else { return }

        cooldown.markNotified(baseDelay: settings.cooldownSeconds)
        rateLimiter.markNotified()

        let detection = BirdDetection(
            birdName: response.bird,
            scientificName: response.scientificName,
            confidence: response.confidence,
            birdId: response.id,
            inferenceMs: response.timeMs
        )
        detections.insert(detection, at: 0)
        if detections.count > 50 {
            detections = Array(detections.prefix(50))
        }

        if settings.notificationsEnabled {
            await sendNotification(for: detection)
        }
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
        content.body = String(format: "Confidence %.0f%%", detection.confidence * 100)
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
