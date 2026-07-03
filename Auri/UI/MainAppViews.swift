import AppKit
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            MonitorView(viewModel: viewModel)
                .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
                .tag(BirdDetectionViewModel.MainWindowTab.monitor)

            OfflineAnalysisTabView(viewModel: viewModel)
                .tabItem { Label("Offline", systemImage: "doc.text.magnifyingglass") }
                .tag(BirdDetectionViewModel.MainWindowTab.offline)

            HistoryTabView(viewModel: viewModel)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(BirdDetectionViewModel.MainWindowTab.history)

            IgnoreListTabView(viewModel: viewModel)
                .tabItem { Label("Ignore List", systemImage: "eye.slash") }
                .tag(BirdDetectionViewModel.MainWindowTab.ignoreList)

            EBirdBatchView(viewModel: viewModel)
                .tabItem { Label("eBird", systemImage: "bird") }
                .tag(BirdDetectionViewModel.MainWindowTab.eBird)

            SettingsView(viewModel: viewModel, embedded: true)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(BirdDetectionViewModel.MainWindowTab.settings)
        }
        .frame(minWidth: 900, minHeight: 640)
        .sheet(isPresented: $viewModel.showingEBirdForm) {
            EBirdFormView(
                detection: viewModel.selectedDetection,
                species: viewModel.species,
                prefilledCoordinate: viewModel.locationProvider.lastKnownLocation?.coordinate
            )
        }
    }
}

struct InferenceStatsView: View {
    let stats: RecognitionPipelineStats
    let isListening: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(stats.isBehindRealtime ? .orange : .secondary)
            }

            if let ms = stats.lastInferenceMs {
                Text("Inference \(Self.formatInferenceDuration(ms))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(stats.isBehindRealtime ? .orange : .secondary)
            }

            if stats.skippedWindows > 0 {
                Text("Skipped: \(stats.skippedWindows)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }

            if stats.silentWindowsSkipped > 0 {
                Text("Silent: \(stats.silentWindowsSkipped)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Windows skipped by the silence gate without running inference")
            }

            if stats.isCriticallyBehind {
                Text("Inference falling behind real-time")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
    }

    private var indicatorColor: Color {
        if !isListening { return .secondary }
        if stats.isInFlight { return .yellow }
        if stats.isBehindRealtime { return .orange }
        return .green
    }

    private var statusText: String {
        if !isListening { return "Inference idle" }
        if stats.isInFlight { return "Recognizing…" }
        if stats.isBehindRealtime { return "Inference behind real-time" }
        return "Inference on pace"
    }

    private static func formatInferenceDuration(_ ms: Int) -> String {
        if ms >= 10_000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        if ms >= 1_000 {
            return String(format: "%.2fs", Double(ms) / 1000)
        }
        return "\(ms) ms"
    }
}

struct AudioStatsView: View {
    let stats: AudioMeterStats

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stats.isReceivingAudio ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(stats.isReceivingAudio ? "Processing" : "No buffers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statLabel("RMS", value: stats.rmsDB)
            statLabel("Peak", value: stats.peakDB)
            Text("Buffers: \(stats.buffersReceived)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func statLabel(_ title: String, value: Float) -> some View {
        Text("\(title) \(value, format: .number.precision(.fractionLength(1))) dBFS")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

struct RuntimeControlsView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            modelRow
            listeningRow
        }
    }

    private var modelRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(modelIndicatorColor)
                .frame(width: 8, height: 8)
            Text(viewModel.modelStatusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if case .failed = viewModel.modelState {
                Button("Reload Model") { viewModel.reloadModel() }
            }
        }
    }

    private var listeningRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isListening ? .green : .red)
                .frame(width: 8, height: 8)
            Text(viewModel.listeningStatusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if viewModel.canStopListening {
                Button("Stop Listening") { viewModel.stopListening() }
            } else if viewModel.canStartListening {
                Button("Start Listening") { viewModel.startListening() }
            }
        }
    }

    private var modelIndicatorColor: Color {
        switch viewModel.modelState {
        case .ready: return .green
        case .loading: return .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }
}

struct MonitorView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject private var audioHandler: AudioHandler
    @ObservedObject private var settings: AppSettings

    init(viewModel: BirdDetectionViewModel) {
        self.viewModel = viewModel
        self.audioHandler = viewModel.audioHandler
        self.settings = viewModel.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RuntimeControlsView(viewModel: viewModel)

            VStack(alignment: .leading, spacing: 8) {
                Text("Live spectrogram")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                sensitivityControl
                ConfidenceThresholdControls(
                    settings: settings,
                    stats: viewModel.recognitionStats,
                    onApplySuggested: viewModel.applySuggestedConfidenceThreshold
                )
                AudioStatsView(stats: viewModel.meterStats)
                InferenceStatsView(stats: viewModel.recognitionStats, isListening: viewModel.isListening)
                SpectrogramView(snapshot: audioHandler.spectrogram)
                    .layoutPriority(-1)
                    .onAppear { audioHandler.setSpectrogramVisible(true) }
                    .onDisappear { audioHandler.setSpectrogramVisible(false) }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Text("Recent detections")
                    .font(.headline)
                if viewModel.isListening {
                    Text(
                        "\(viewModel.recognitionStats.belowThresholdCount) below \(Int(settings.confidenceThreshold * 100))%"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear recent") {
                    viewModel.clearRecentDetections()
                }
                .font(.caption)
                .disabled(viewModel.detections.isEmpty)
            }

            if viewModel.detections.isEmpty {
                Text("No birds detected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.detections) { detection in
                            DetectionCardView(
                                detection: detection,
                                lifetimeCount: viewModel.historyStore.lifetimeCount(for: detection.birdId),
                                isIgnored: viewModel.isIgnored(detection),
                                onIgnore: { viewModel.ignore(detection: detection) },
                                onDelete: { viewModel.deleteDetection(detection) },
                                onSubmit: { viewModel.submitToEBirdSheet(for: detection) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sensitivityControl: some View {
        HStack(spacing: 12) {
            Text("Sensitivity")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $settings.inputGainDB, in: 0...36, step: 1)
            Text("+\(Int(settings.inputGainDB)) dB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .onChange(of: settings.inputGainDB) { _, gain in
            audioHandler.setInputGain(dB: gain)
        }
    }

}

extension BirdDetectionViewModel {
    var modelStatusLabel: String {
        switch modelState {
        case .stopped: return "Model stopped"
        case .loading: return "Loading model"
        case .ready: return "Model ready"
        case .failed: return "Model failed"
        }
    }

    var listeningStatusLabel: String {
        if isListening { return "Listening" }
        if audioHandler.isPermissionDenied { return "Microphone access denied" }
        if !audioHandler.permissionGranted { return "Microphone access required" }
        return "Not listening"
    }
}

struct IgnoreListTabView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject private var settings: AppSettings

    init(viewModel: BirdDetectionViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
    }

    private var ignoredNames: [String] {
        settings.ignoredSpeciesNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suppressed detections")
                        .font(.headline)

                    if ignoredNames.isEmpty {
                        Text("No ignored species yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ignoredNames, id: \.self) { name in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                    if let count = settings.suppressedCounts[name], count > 0 {
                                        Text("\(count) detections suppressed")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("No suppressions yet")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Remove") {
                                    settings.unignore(speciesName: name, matchingSpecies: viewModel.species)
                                    viewModel.objectWillChange.send()
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Divider()

                IgnoreListSettingsView(settings: settings, species: viewModel.species)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await viewModel.reloadSpeciesIfNeeded()
        }
    }
}

struct EBirdBatchView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var historyStore: RecognitionHistoryStore

    @State private var copyFeedback = ""

    init(viewModel: BirdDetectionViewModel) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
        self.historyStore = viewModel.historyStore
    }

    private var sessionSpecies: [SessionSpeciesSummary] {
        viewModel.sessionSpecies
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("eBird species list")
                    .font(.title2.bold())

                Text(sessionWindowDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Unique species detected since you last cleared Recent detections. Copy the list and enter observations manually on eBird.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Copy species list") {
                        copySpeciesList()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sessionSpecies.isEmpty)

                    Link("Open eBird submission page", destination: URL(string: "https://ebird.org/submit")!)
                }

                if !copyFeedback.isEmpty {
                    Text(copyFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if sessionSpecies.isEmpty {
                    Text("No species detected in this session yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(sessionSpecies.count) species")
                        .font(.headline)

                    ForEach(sessionSpecies) { species in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(species.birdName)
                                .font(.body)
                            Text(species.scientificName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if species.detectionCount > 1 {
                                Text("\(species.detectionCount) detections · last \(species.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                EBirdAttributionView()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionWindowDescription: String {
        let start = settings.recentClearedAt
        let duration = Self.formatDuration(since: start)
        return "Since \(start.formatted(date: .abbreviated, time: .shortened)) (\(duration))"
    }

    private func copySpeciesList() {
        let lines = sessionSpecies.map { "\($0.birdName) (\($0.scientificName))" }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyFeedback = "\(lines.count) species copied to clipboard."
    }

    private static func formatDuration(since date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        if interval < 60 {
            return "just now"
        }
        if interval < 3600 {
            let minutes = Int(interval / 60)
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        if interval < 86_400 {
            let hours = interval / 3600
            return hours < 2 ? String(format: "%.1f hour", hours) : String(format: "%.1f hours", hours)
        }
        let days = interval / 86_400
        return days < 2 ? String(format: "%.1f day", days) : String(format: "%.1f days", days)
    }
}

struct WindowOpener: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                viewModel.bindOpenMainWindow {
                    openWindow(id: "main")
                }
            }
    }
}
