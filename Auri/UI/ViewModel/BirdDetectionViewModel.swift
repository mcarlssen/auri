import AppKit
import CoreLocation
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
    /// Raw per-window model output for the Debug accordion. Only populated while
    /// debug capture is enabled (the accordion is open); newest first.
    @Published private(set) var modelOutputLog: [ModelOutputEntry] = []
    @Published var showingEBirdForm = false
    @Published var selectedDetection: BirdDetection?
    @Published var selectedTab: MainWindowTab = .monitor

    enum MainWindowTab: Hashable {
        case monitor
        case offline
        case history
        case eBird
        case settings
    }

    private var openMainWindowHandler: (() -> Void)?

    let settings = AppSettings.shared
    let audioHandler = AudioHandler()
    let historyStore = RecognitionHistoryStore()
    let locationProvider = LocationProvider()
    /// Retains and plays the short audio window behind each live detection.
    let audioClips = DetectionAudioStore()

    private let recognizer = BirdNetCoreMLRecognizer()
    private var speciesCooldown = SpeciesCooldown()
    private var fileAnalysisCooldown = TimelineSpeciesCooldown()
    private var rateLimiter = NotificationRateLimiter()
    private var confidenceEstimator = ConfidenceRollingEstimator()
    /// Temporal corroboration for LIVE detections: a species must clear threshold
    /// in enough overlapping windows before it qualifies. Reset when listening
    /// (re)starts and when the window cadence changes.
    private var corroborator = DetectionCorroborator(
        horizonSeconds: BirdDetectionViewModel.corroborationHorizonSeconds
    )
    private let recognitionQueue = RecognitionSerialQueue()
    private var runtimeTask: Task<Void, Never>?
    private var fileAnalysisTask: Task<Void, Never>?
    private var hasBootstrapped = false
    /// A species not on the regional eBird list (rarity `.unusual`) is hidden
    /// unless it scores at least this high — a very confident hit still surfaces
    /// as a possible rare sighting rather than being filtered outright.
    static let unusualSpeciesConfidenceFloor = 0.75
    /// Corroborating windows must fall within one BirdNET window length of each
    /// other so only overlapping looks at the same ~3 s of audio combine.
    private static let corroborationHorizonSeconds =
        Double(BirdNetCoreMLRecognizer.windowSamples) / Double(BirdNetCoreMLRecognizer.modelSampleRate)
    private var debugCaptureEnabled = false
    private let maxModelOutputEntries = 150
    /// Species heard this session (since last clear), for new-species detection.
    private var sessionSpeciesIDs: Set<Int> = []

    /// Lowercased scientific names expected in the current region, mirrored from
    /// `EBirdRegionalService` so detections and the live model-output feed can be
    /// range-filtered synchronously on the main actor.
    private var regionalInRegionScientificNames: Set<String> = []
    /// Lowercased scientific names the eBird taxonomy knows about. A name absent
    /// here can't be classified in/out of region, so it is never filtered out.
    private var regionalKnownScientificNames: Set<String> = []

    private enum RegionStatus {
        case unknown
        case inRegion
        case outOfRegion
    }

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
            corroborator.reset()
            recognitionStats = RecognitionPipelineStats()
            await audioHandler.requestPermission()
            await startAudioIfPossible()
            await refreshRuntime()
        }
    }

    func stopListening() {
        settings.recordingEnabled = false
        audioHandler.stop()
        corroborator.reset()
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
        guard settings.locationFilteringEnabled else {
            RecognitionLogger.log("location filtering disabled", category: "Location")
            locationProvider.stop()
            regionalLabel = nil
            regionalInRegionScientificNames = []
            regionalKnownScientificNames = []
            return
        }

        if settings.manualLocationEnabled {
            RecognitionLogger.log("location filtering on; using manual coordinate", category: "Location")
            locationProvider.stop()
        } else {
            RecognitionLogger.log("location filtering on; requesting Core Location access", category: "Location")
            locationProvider.request()
        }
        Task { await refreshRegionalDataIfNeeded() }
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
            // The window cadence changed, so the corroboration requirement and any
            // in-flight window observations no longer line up; start fresh.
            corroborator.reset()
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

    func submitToEBirdSheet(for detection: BirdDetection) {
        selectedDetection = detection
        showingEBirdForm = true
    }

    /// Open the eBird page for a detected species. With an eBird API key we
    /// resolve the exact species page (ebird.org/species/CODE); otherwise we
    /// fall back to an eBird search for the species name.
    func openEBirdInfo(for detection: BirdDetection) {
        let scientificName = detection.scientificName
        let apiKey = settings.resolvedEBirdApiKey
        Task {
            var url: URL?
            if !apiKey.isEmpty,
               let code = await EBirdRegionalService.shared.eBirdSpeciesCode(
                   for: scientificName,
                   apiKey: apiKey
               ) {
                url = URL(string: "https://ebird.org/species/\(code)")
            }
            let target = url ?? Self.eBirdSearchURL(forSpecies: scientificName)
            if let target {
                NSWorkspace.shared.open(target)
            }
        }
    }

    private static func eBirdSearchURL(forSpecies scientificName: String) -> URL? {
        var components = URLComponents(string: "https://ebird.org/species/search")
        components?.queryItems = [URLQueryItem(name: "q", value: scientificName)]
        return components?.url
    }

    func deleteDetection(_ detection: BirdDetection) {
        detections.removeAll { $0.id == detection.id }
        historyStore.remove(id: detection.id)
        audioClips.remove([detection.id])
        if selectedDetection?.id == detection.id {
            selectedDetection = nil
        }
    }

    /// Remove every detection in a grouped feed entry at once.
    func deleteDetections(in group: DetectionGroup) {
        let ids = Set(group.detections.map(\.id))
        detections.removeAll { ids.contains($0.id) }
        for id in ids {
            historyStore.remove(id: id)
        }
        audioClips.remove(ids)
        if let selected = selectedDetection?.id, ids.contains(selected) {
            selectedDetection = nil
        }
    }

    func clearRecentDetections() {
        detections.removeAll()
        sessionSpeciesIDs.removeAll()
        audioClips.removeAll()
        settings.recentClearedAt = Date()
        selectedDetection = nil
    }

    /// The Debug accordion toggles live model-output capture on/off so there is
    /// no per-window overhead while it is closed. Clears the log when disabled.
    func setDebugCaptureEnabled(_ enabled: Bool) {
        guard debugCaptureEnabled != enabled else { return }
        debugCaptureEnabled = enabled
        if !enabled {
            modelOutputLog.removeAll()
        }
    }

    func clearModelOutputLog() {
        modelOutputLog.removeAll()
    }

    /// Scores below this are noise for debugging purposes and are omitted from
    /// the model-output feed.
    static let debugMinConfidence = 0.05

    /// Record one window's raw model scores (top species, pre-threshold) so the
    /// Debug accordion can show what is firing below the confidence threshold.
    /// Scores under `debugMinConfidence` are dropped as noise.
    private func captureModelOutput(_ responses: [RecognitionResponse]) {
        let visible = responses.filter {
            $0.confidence >= Self.debugMinConfidence
                && !isOutOfRangeSuppressed(scientificName: $0.scientificName, confidence: $0.confidence)
        }
        guard !visible.isEmpty else { return }
        let threshold = settings.confidenceThreshold
        let now = Date()
        let entries = visible.map { response in
            ModelOutputEntry(
                birdName: response.bird,
                scientificName: response.scientificName,
                confidence: response.confidence,
                threshold: threshold,
                timestamp: now
            )
        }
        modelOutputLog.insert(contentsOf: entries, at: 0)
        if modelOutputLog.count > maxModelOutputEntries {
            modelOutputLog = Array(modelOutputLog.prefix(maxModelOutputEntries))
        }
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
        guard let location = effectiveLocation else { return }
        await EBirdRegionalService.shared.refreshIfNeeded(
            location: location,
            apiKey: settings.resolvedEBirdApiKey
        )
        let snapshot = await EBirdRegionalService.shared.regionalSnapshot()
        let changed = regionalLabel != snapshot.regionLabel
            || regionalInRegionScientificNames.count != snapshot.inRegionScientificNames.count
            || regionalKnownScientificNames.count != snapshot.knownScientificNames.count
        regionalLabel = snapshot.regionLabel
        regionalInRegionScientificNames = snapshot.inRegionScientificNames
        regionalKnownScientificNames = snapshot.knownScientificNames
        if changed {
            RecognitionLogger.log(
                "regional data updated: region=\(snapshot.regionLabel ?? "none") " +
                "inRegion=\(snapshot.inRegionScientificNames.count) taxonomy=\(snapshot.knownScientificNames.count)",
                category: "Location"
            )
        }
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

            if debugCaptureEnabled, source == .live {
                captureModelOutput(result.detections)
            }

            var recordedAny = false
            for response in result.detections {
                if await handleRecognition(
                    response,
                    source: source,
                    sourceFileName: sourceFileName,
                    audioOffsetSeconds: audioOffsetSeconds,
                    notify: notify,
                    windowData: data,
                    windowSampleRate: sampleRate
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
        notify: Bool = true,
        windowData: Data? = nil,
        windowSampleRate: Int = 0
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

        // LIVE audio, opt-in only: when corroboration is enabled, require the
        // species to clear threshold across multiple overlapping windows before it
        // qualifies, dropping isolated single-window false positives. With overlap
        // off there is only one look per window, so the requirement collapses to 1
        // (pass-through). When the setting is off (the default) a single window is
        // enough, so brief and isolated calls surface immediately. The .file path
        // uses its own timeline cooldown, so leave it — and its confidence — untouched.
        var effectiveConfidence = response.confidence
        if source == .live, settings.corroborationEnabled {
            let hopSamples = settings.detectionOverlap.hopSamples(
                windowSamples: BirdNetCoreMLRecognizer.windowSamples
            )
            let requiredWindows = hopSamples < BirdNetCoreMLRecognizer.windowSamples ? 2 : 1
            guard let corroboratedConfidence = corroborator.corroborate(
                speciesId: response.id,
                confidence: response.confidence,
                required: requiredWindows
            ) else {
                return false
            }
            effectiveConfidence = corroboratedConfidence
        }

        let rarity = rarityInfo(scientificName: response.scientificName)

        // Judge the out-of-range floor against the corroborated confidence so a
        // strong, multi-window rare-species hit can still surface.
        if isOutOfRangeSuppressed(scientificName: response.scientificName, confidence: effectiveConfidence) {
            RecognitionLogger.log(
                "suppressed out-of-range species below \(Int(Self.unusualSpeciesConfidenceFloor * 100))% floor: " +
                "\(response.bird) conf=\(String(format: "%.3f", effectiveConfidence))",
                category: "Location"
            )
            return false
        }

        if source == .file {
            let offset = audioOffsetSeconds ?? 0
            guard fileAnalysisCooldown.shouldAllow(speciesId: response.id, now: offset) else {
                return false
            }
        }

        // "New this session" = first live detection of this species since the
        // last clear; drives the optional new-species-only notification mode.
        let isNewThisSession = source == .live && !sessionSpeciesIDs.contains(response.id)

        let detection = BirdDetection(
            birdName: response.bird,
            scientificName: response.scientificName,
            confidence: effectiveConfidence,
            birdId: response.id,
            inferenceMs: response.timeMs,
            source: source,
            sourceFileName: sourceFileName,
            audioOffsetSeconds: audioOffsetSeconds,
            rarity: rarity
        )
        recordDetection(detection)
        if source == .live {
            sessionSpeciesIDs.insert(response.id)
            if let windowData {
                audioClips.store(id: detection.id, data: windowData, sampleRate: windowSampleRate)
            }
        }

        if source == .file {
            fileAnalysisCooldown.markQualified(
                speciesId: response.id,
                cooldownSeconds: settings.perSpeciesCooldownSeconds,
                now: audioOffsetSeconds ?? 0
            )
        }

        var shouldNotify = notify
        if shouldNotify, source == .live, settings.notifyNewSpeciesOnly, !isNewThisSession {
            // In new-species-only mode, repeats of a species already heard this
            // session don't notify.
            shouldNotify = false
        }
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

    /// The location used for regional filtering and eBird form prefill: a manually
    /// entered coordinate when manual mode is on and valid, otherwise the Core
    /// Location fix.
    var effectiveLocation: CLLocation? {
        if settings.manualLocationEnabled {
            let lat = settings.manualLatitude
            let lon = settings.manualLongitude
            guard (-90...90).contains(lat), (-180...180).contains(lon), !(lat == 0 && lon == 0) else {
                return nil
            }
            return CLLocation(latitude: lat, longitude: lon)
        }
        return locationProvider.lastKnownLocation
    }

    /// Where a species sits relative to the current region, judged from the eBird
    /// snapshot. `.unknown` when filtering is off, region data hasn't loaded, or the
    /// species isn't in the eBird taxonomy (so it can't be judged and isn't filtered).
    private func regionStatus(scientificName: String) -> RegionStatus {
        guard settings.locationFilteringEnabled, !regionalKnownScientificNames.isEmpty else {
            return .unknown
        }
        let key = scientificName.lowercased()
        guard regionalKnownScientificNames.contains(key) else { return .unknown }
        return regionalInRegionScientificNames.contains(key) ? .inRegion : .outOfRegion
    }

    private func rarityInfo(scientificName: String) -> RarityInfo? {
        guard settings.locationFilteringEnabled else { return nil }
        switch regionStatus(scientificName: scientificName) {
        case .inRegion:
            return RarityInfo(level: .expected, regionLabel: regionalLabel, frequencyPercent: nil)
        case .outOfRegion:
            return RarityInfo(level: .unusual, regionLabel: regionalLabel, frequencyPercent: nil)
        case .unknown:
            return RarityInfo(level: .unknown, regionLabel: regionalLabel, frequencyPercent: nil)
        }
    }

    /// True when a species is out of range for the current locale and not confident
    /// enough to surface as a possible rare sighting. Drives both committed
    /// detections and what the live model-output feed shows.
    private func isOutOfRangeSuppressed(scientificName: String, confidence: Double) -> Bool {
        guard settings.locationFilteringEnabled else { return false }
        guard regionStatus(scientificName: scientificName) == .outOfRegion else { return false }
        return confidence < Self.unusualSpeciesConfidenceFloor
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
