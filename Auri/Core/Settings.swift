import Foundation

enum SpectrogramFFTSize: Int, CaseIterable, Identifiable, Codable {
    case size1024 = 1024
    case size2048 = 2048
    case size4096 = 4096
    case size8192 = 8192

    var id: Int { rawValue }

    var label: String { "\(rawValue)" }
}

enum SpectrogramOverlap: Double, CaseIterable, Identifiable, Codable {
    case half = 0.5
    case threeQuarters = 0.75
    case sevenEighths = 0.875

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .half: return "50%"
        case .threeQuarters: return "75%"
        case .sevenEighths: return "87.5%"
        }
    }

    func hopSize(fftSize: Int) -> Int {
        max(1, Int(Double(fftSize) * (1 - rawValue)))
    }
}

/// Overlap between consecutive BirdNET analysis windows. The model's input is a
/// fixed 3-second window; overlap controls how often a new window is analyzed.
enum DetectionOverlap: String, CaseIterable, Identifiable, Codable {
    case off
    case half
    case twoThirds
    case threeQuarters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "None (every 3 s)"
        case .half: return "50% (every 1.5 s)"
        case .twoThirds: return "67% (every 1 s)"
        case .threeQuarters: return "75% (every 0.75 s)"
        }
    }

    private var windowDivisor: Int {
        switch self {
        case .off: return 1
        case .half: return 2
        case .twoThirds: return 3
        case .threeQuarters: return 4
        }
    }

    func hopSamples(windowSamples: Int) -> Int {
        max(1, windowSamples / windowDivisor)
    }
}

enum SpectrogramFrequencyScale: String, CaseIterable, Identifiable, Codable {
    case mel
    case linear
    case logarithmic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mel: return "Mel (perceptual)"
        case .linear: return "Linear"
        case .logarithmic: return "Logarithmic"
        }
    }

    /// Map frequency (Hz) to a 0…1 display position between min and max Hz.
    func displayPosition(for frequency: Float, minHz: Float, maxHz: Float) -> Float {
        switch self {
        case .linear:
            let span = max(maxHz - minHz, 1)
            return (frequency - minHz) / span
        case .logarithmic:
            let logMin = log10(max(minHz, 1))
            let logMax = log10(max(maxHz, 1))
            let logSpan = max(logMax - logMin, 1e-6)
            return (log10f(max(frequency, 1)) - logMin) / logSpan
        case .mel:
            let melMin = Self.hzToMel(minHz)
            let melMax = Self.hzToMel(maxHz)
            let melSpan = max(melMax - melMin, 1e-6)
            return (Self.hzToMel(frequency) - melMin) / melSpan
        }
    }

    /// Map a 0…1 display position back to frequency (Hz) for axis labels.
    func frequency(atPosition position: Float, minHz: Float, maxHz: Float) -> Float {
        let clamped = max(0, min(1, position))
        switch self {
        case .linear:
            return minHz + clamped * (maxHz - minHz)
        case .logarithmic:
            let logMin = log10(max(minHz, 1))
            let logMax = log10(max(maxHz, 1))
            return pow(10, logMin + clamped * (logMax - logMin))
        case .mel:
            let melMin = Self.hzToMel(minHz)
            let melMax = Self.hzToMel(maxHz)
            return Self.melToHz(melMin + clamped * (melMax - melMin))
        }
    }

    private static func hzToMel(_ hz: Float) -> Float {
        2595 * log10f(1 + hz / 700)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700 * (powf(10, mel / 2595) - 1)
    }
}

enum AudioInputSource: String, CaseIterable, Identifiable, Codable {
    case defaultMic
    case blackhole
    case selectedDevice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultMic: return "Default Microphone"
        case .blackhole: return "BlackHole (System Audio)"
        case .selectedDevice: return "Selected Device"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var confidenceThreshold: Double {
        didSet { save() }
    }

    @Published var autoGainEnabled: Bool {
        didSet { save() }
    }

    @Published var detectionOverlap: DetectionOverlap {
        didSet { save() }
    }

    /// Skip BirdNET inference for windows whose peak stays below the silence threshold.
    @Published var silenceSkipEnabled: Bool {
        didSet { save() }
    }

    @Published var silenceSkipThresholdDB: Double {
        didSet { save() }
    }

    @Published var cooldownSeconds: Double {
        didSet { save() }
    }

    /// Minimum seconds between notifications for the same species.
    @Published var perSpeciesCooldownSeconds: Double {
        didSet { save() }
    }

    @Published var locationFilteringEnabled: Bool {
        didSet { save() }
    }

    /// Use a manually entered coordinate for regional filtering instead of Core
    /// Location. Lets regional filtering work without granting the system location
    /// permission.
    @Published var manualLocationEnabled: Bool {
        didSet { save() }
    }

    @Published var manualLatitude: Double {
        didSet { save() }
    }

    @Published var manualLongitude: Double {
        didSet { save() }
    }

    @Published var eBirdApiKey: String {
        didSet { save() }
    }

    @Published var notificationsEnabled: Bool {
        didSet { save() }
    }

    @Published var notificationSoundEnabled: Bool {
        didSet { save() }
    }

    @Published var maxNotificationsPerHour: Int {
        didSet { save() }
    }

    @Published var ignoredSpeciesIDs: Set<Int> {
        didSet { save() }
    }

    @Published var ignoredSpeciesNames: Set<String> {
        didSet { save() }
    }

    @Published var audioInputSource: AudioInputSource {
        didSet { save() }
    }

    @Published var selectedDeviceUID: String {
        didSet { save() }
    }

    @Published var recordingEnabled: Bool {
        didSet { save() }
    }

    @Published var startListeningAtLogin: Bool {
        didSet { save() }
    }

    @Published var launchAtLogin: Bool {
        didSet { save() }
    }

    @Published var debugLogging: Bool {
        didSet { save() }
    }

    /// Software gain applied before BirdNET and spectrogram processing.
    @Published var inputGainDB: Double {
        didSet { save() }
    }

    @Published var spectrogramFFTSize: SpectrogramFFTSize {
        didSet { save() }
    }

    @Published var spectrogramOverlap: SpectrogramOverlap {
        didSet { save() }
    }

    @Published var spectrogramFrequencyScale: SpectrogramFrequencyScale {
        didSet { save() }
    }

    @Published var spectrogramMinFrequency: Double {
        didSet {
            if spectrogramMinFrequency >= spectrogramMaxFrequency {
                spectrogramMaxFrequency = min(20_000, spectrogramMinFrequency + 100)
            }
            save()
        }
    }

    @Published var spectrogramMaxFrequency: Double {
        didSet {
            if spectrogramMaxFrequency <= spectrogramMinFrequency {
                spectrogramMinFrequency = max(20, spectrogramMaxFrequency - 100)
            }
            save()
        }
    }

    @Published var suppressedCounts: [String: Int] {
        didSet { save() }
    }

    /// Detections after this time count toward the eBird session species list.
    @Published var recentClearedAt: Date {
        didSet { save() }
    }

    var spectrogramHopSize: Int {
        spectrogramOverlap.hopSize(fftSize: spectrogramFFTSize.rawValue)
    }

    /// UserDefaults value, falling back to `EBIRD_API_KEY` in `.env` when unset.
    var resolvedEBirdApiKey: String {
        let trimmed = eBirdApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return DotEnv.value(for: "EBIRD_API_KEY") ?? ""
    }

    var eBirdApiKeySourceLabel: String? {
        let trimmed = eBirdApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return nil }
        return resolvedEBirdApiKey.isEmpty ? nil : "Loaded from .env"
    }

    private let defaults = UserDefaults.standard

    private init() {
        confidenceThreshold = defaults.object(forKey: "confidenceThreshold") as? Double ?? 0.35
        autoGainEnabled = defaults.object(forKey: "autoGainEnabled") as? Bool ?? true
        detectionOverlap = DetectionOverlap(
            rawValue: defaults.string(forKey: "detectionOverlap") ?? ""
        ) ?? .half
        silenceSkipEnabled = defaults.object(forKey: "silenceSkipEnabled") as? Bool ?? true
        silenceSkipThresholdDB = defaults.object(forKey: "silenceSkipThresholdDB") as? Double ?? -65
        cooldownSeconds = defaults.object(forKey: "cooldownSeconds") as? Double ?? 5
        perSpeciesCooldownSeconds = defaults.object(forKey: "perSpeciesCooldownSeconds") as? Double ?? 3600
        locationFilteringEnabled = defaults.object(forKey: "locationFilteringEnabled") as? Bool ?? false
        manualLocationEnabled = defaults.object(forKey: "manualLocationEnabled") as? Bool ?? false
        manualLatitude = defaults.object(forKey: "manualLatitude") as? Double ?? 0
        manualLongitude = defaults.object(forKey: "manualLongitude") as? Double ?? 0
        eBirdApiKey = defaults.string(forKey: "eBirdApiKey") ?? ""
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        notificationSoundEnabled = defaults.object(forKey: "notificationSoundEnabled") as? Bool ?? true
        maxNotificationsPerHour = defaults.object(forKey: "maxNotificationsPerHour") as? Int ?? 30
        ignoredSpeciesIDs = Set(defaults.array(forKey: "ignoredSpeciesIDs") as? [Int] ?? [])
        ignoredSpeciesNames = Set(defaults.array(forKey: "ignoredSpeciesNames") as? [String] ?? [])
        audioInputSource = AudioInputSource(rawValue: defaults.string(forKey: "audioInputSource") ?? "") ?? .defaultMic
        selectedDeviceUID = defaults.string(forKey: "selectedDeviceUID") ?? ""
        recordingEnabled = defaults.object(forKey: "recordingEnabled") as? Bool ?? true
        startListeningAtLogin = defaults.object(forKey: "startListeningAtLogin") as? Bool
            ?? (defaults.object(forKey: "recordingEnabled") as? Bool ?? true)
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        debugLogging = defaults.object(forKey: "debugLogging") as? Bool ?? false
        inputGainDB = defaults.object(forKey: "inputGainDB") as? Double ?? 12
        let fftRaw = defaults.object(forKey: "spectrogramFFTSize") as? Int ?? SpectrogramFFTSize.size2048.rawValue
        spectrogramFFTSize = SpectrogramFFTSize(rawValue: fftRaw) ?? .size2048
        let overlapRaw = defaults.object(forKey: "spectrogramOverlap") as? Double ?? SpectrogramOverlap.sevenEighths.rawValue
        spectrogramOverlap = SpectrogramOverlap(rawValue: overlapRaw) ?? .sevenEighths
        spectrogramFrequencyScale = SpectrogramFrequencyScale(
            rawValue: defaults.string(forKey: "spectrogramFrequencyScale") ?? ""
        ) ?? .mel
        spectrogramMinFrequency = defaults.object(forKey: "spectrogramMinFrequency") as? Double ?? 100
        spectrogramMaxFrequency = defaults.object(forKey: "spectrogramMaxFrequency") as? Double ?? 15_000
        suppressedCounts = defaults.dictionary(forKey: "suppressedCounts") as? [String: Int] ?? [:]
        recentClearedAt = defaults.object(forKey: "recentClearedAt") as? Date ?? Date()
    }

    func ignore(bird: Bird) {
        ignoredSpeciesIDs.insert(bird.id)
        ignoredSpeciesNames.insert(bird.commonName)
    }

    func ignore(speciesName: String) {
        let trimmed = speciesName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ignoredSpeciesNames.insert(trimmed)
    }

    func ignore(detection: BirdDetection) {
        ignoredSpeciesIDs.insert(detection.birdId)
        ignoredSpeciesNames.insert(detection.birdName)
    }

    func isIgnored(detection: BirdDetection) -> Bool {
        ignoredSpeciesIDs.contains(detection.birdId) || ignoredSpeciesNames.contains(detection.birdName)
    }

    func recordSuppressed(birdName: String) {
        suppressedCounts[birdName, default: 0] += 1
    }

    func unignore(bird: Bird) {
        ignoredSpeciesIDs.remove(bird.id)
        ignoredSpeciesNames.remove(bird.commonName)
    }

    func unignore(speciesName: String, matchingSpecies: [Bird] = []) {
        ignoredSpeciesNames.remove(speciesName)
        suppressedCounts.removeValue(forKey: speciesName)
        for bird in matchingSpecies where bird.commonName == speciesName {
            ignoredSpeciesIDs.remove(bird.id)
        }
    }

    private func save() {
        defaults.set(confidenceThreshold, forKey: "confidenceThreshold")
        defaults.set(autoGainEnabled, forKey: "autoGainEnabled")
        defaults.set(detectionOverlap.rawValue, forKey: "detectionOverlap")
        defaults.set(silenceSkipEnabled, forKey: "silenceSkipEnabled")
        defaults.set(silenceSkipThresholdDB, forKey: "silenceSkipThresholdDB")
        defaults.set(cooldownSeconds, forKey: "cooldownSeconds")
        defaults.set(perSpeciesCooldownSeconds, forKey: "perSpeciesCooldownSeconds")
        defaults.set(locationFilteringEnabled, forKey: "locationFilteringEnabled")
        defaults.set(manualLocationEnabled, forKey: "manualLocationEnabled")
        defaults.set(manualLatitude, forKey: "manualLatitude")
        defaults.set(manualLongitude, forKey: "manualLongitude")
        defaults.set(eBirdApiKey, forKey: "eBirdApiKey")
        defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(notificationSoundEnabled, forKey: "notificationSoundEnabled")
        defaults.set(maxNotificationsPerHour, forKey: "maxNotificationsPerHour")
        defaults.set(Array(ignoredSpeciesIDs), forKey: "ignoredSpeciesIDs")
        defaults.set(Array(ignoredSpeciesNames), forKey: "ignoredSpeciesNames")
        defaults.set(audioInputSource.rawValue, forKey: "audioInputSource")
        defaults.set(selectedDeviceUID, forKey: "selectedDeviceUID")
        defaults.set(recordingEnabled, forKey: "recordingEnabled")
        defaults.set(startListeningAtLogin, forKey: "startListeningAtLogin")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(debugLogging, forKey: "debugLogging")
        defaults.set(inputGainDB, forKey: "inputGainDB")
        defaults.set(spectrogramFFTSize.rawValue, forKey: "spectrogramFFTSize")
        defaults.set(spectrogramOverlap.rawValue, forKey: "spectrogramOverlap")
        defaults.set(spectrogramFrequencyScale.rawValue, forKey: "spectrogramFrequencyScale")
        defaults.set(spectrogramMinFrequency, forKey: "spectrogramMinFrequency")
        defaults.set(spectrogramMaxFrequency, forKey: "spectrogramMaxFrequency")
        defaults.set(suppressedCounts, forKey: "suppressedCounts")
        defaults.set(recentClearedAt, forKey: "recentClearedAt")
    }
}
