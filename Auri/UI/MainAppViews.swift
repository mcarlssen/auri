import AppKit
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            ListenView(viewModel: viewModel)
                .tabItem { Label("Listen", systemImage: "waveform.path.ecg") }
                .tag(BirdDetectionViewModel.MainWindowTab.monitor)

            HistoryTabView(viewModel: viewModel)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(BirdDetectionViewModel.MainWindowTab.history)

            OfflineAnalysisTabView(viewModel: viewModel)
                .tabItem { Label("Analyze File", systemImage: "doc.text.magnifyingglass") }
                .tag(BirdDetectionViewModel.MainWindowTab.offline)

            EBirdBatchView(viewModel: viewModel)
                .tabItem { Label("Session List", systemImage: "bird") }
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

enum ListenState: Equatable {
    case listening
    case paused
    case starting
    case micDenied
    case modelFailed(String)

    var label: String {
        switch self {
        case .listening: return "Listening"
        case .paused: return "Paused"
        case .starting: return "Starting…"
        case .micDenied: return "Microphone access denied"
        case .modelFailed: return "Model failed to load"
        }
    }

    var color: Color {
        switch self {
        case .listening: return .green
        case .paused: return .secondary
        case .starting: return .yellow
        case .micDenied, .modelFailed: return .red
        }
    }

    @MainActor
    static func current(viewModel: BirdDetectionViewModel) -> ListenState {
        if case .failed(let message) = viewModel.modelState {
            return .modelFailed(message)
        }
        if viewModel.audioHandler.isPermissionDenied, viewModel.settings.recordingEnabled {
            return .micDenied
        }
        if viewModel.modelState == .loading {
            return .starting
        }
        return viewModel.isListening ? .listening : .paused
    }
}

/// One combined status pill replacing the separate model/listening dot rows.
/// Model state only surfaces when it is the problem.
struct ListenStatusPill: View {
    @ObservedObject var viewModel: BirdDetectionViewModel

    var body: some View {
        let state = ListenState.current(viewModel: viewModel)
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.color)
                    .frame(width: 8, height: 8)
                Text(state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.color == .secondary ? Color.secondary : state.color)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(state.color.opacity(0.13), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(state.label)")

            if case .modelFailed = state {
                Button("Reload Model") { viewModel.reloadModel() }
                    .controlSize(.small)
            }

            Spacer(minLength: 8)

            if viewModel.canStopListening {
                Button("Stop") { viewModel.stopListening() }
                    .controlSize(.small)
            } else if viewModel.canStartListening {
                Button("Start Listening") { viewModel.startListening() }
                    .controlSize(.small)
            }
        }
    }
}

/// Whether the Listen feed shows one card per unique species (default) or a
/// chronological run-grouped timeline.
enum DetectionListMode: String {
    case species
    case timeline
}

struct ListenView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject private var audioHandler: AudioHandler
    @ObservedObject private var settings: AppSettings
    @AppStorage("listenTuningExpanded") private var tuningExpanded = false
    @AppStorage("listenStatsExpanded") private var statsExpanded = false
    @AppStorage("listenDebugExpanded") private var debugExpanded = false
    @AppStorage("listenDetectionMode") private var detectionMode = DetectionListMode.species

    init(viewModel: BirdDetectionViewModel) {
        self.viewModel = viewModel
        self.audioHandler = viewModel.audioHandler
        self.settings = viewModel.settings
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            signalColumn
                .frame(width: 396)
            detectionsColumn
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: signal column

    private var signalColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ListenStatusPill(viewModel: viewModel)

            SpectrogramView(snapshot: audioHandler.spectrogram, markers: spectrogramMarkers)
                .onAppear { audioHandler.setSpectrogramVisible(true) }
                .onDisappear { audioHandler.setSpectrogramVisible(false) }

            levelMeter

            DisclosureGroup(isExpanded: $tuningExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    sensitivityControl
                    ConfidenceThresholdControls(
                        settings: settings,
                        stats: viewModel.recognitionStats,
                        onApplySuggested: viewModel.applySuggestedConfidenceThreshold
                    )
                }
                .padding(.top, 8)
            } label: {
                disclosureLabel("Tuning", summary: tuningSummary)
            }

            DisclosureGroup(isExpanded: $statsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    AudioStatsView(stats: viewModel.meterStats)
                    InferenceStatsView(stats: viewModel.recognitionStats, isListening: viewModel.isListening)
                    Text("\(viewModel.recognitionStats.belowThresholdCount) detections below the \(Int(settings.confidenceThreshold * 100))% threshold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                disclosureLabel("Advanced stats", summary: statsSummary)
            }

            DisclosureGroup(isExpanded: $debugExpanded) {
                debugModelOutput
                    .padding(.top, 8)
            } label: {
                disclosureLabel("Debug", summary: debugSummary)
            }
            .onChange(of: debugExpanded) { _, expanded in
                viewModel.setDebugCaptureEnabled(expanded)
            }
            .onAppear { viewModel.setDebugCaptureEnabled(debugExpanded) }
            .onDisappear { viewModel.setDebugCaptureEnabled(false) }
        }
    }

    /// Live raw model output: every species the model scores each window,
    /// including those below the confidence threshold. Populated only while this
    /// accordion is open (capture is gated on `debugExpanded`).
    private var debugModelOutput: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live model output")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if !viewModel.modelOutputLog.isEmpty {
                    Button("Clear") { viewModel.clearModelOutputLog() }
                        .font(.caption)
                        .controlSize(.small)
                }
            }

            Text("Top species scored each window, including those below your \(Int(settings.confidenceThreshold * 100))% threshold (scores under \(Int(BirdDetectionViewModel.debugMinConfidence * 100))% omitted). Use this to judge whether to adjust it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.modelOutputLog.isEmpty {
                Text(viewModel.isListening ? "Waiting for model output…" : "Start listening to see model output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(viewModel.modelOutputLog) { entry in
                            debugRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func debugRow(_ entry: ModelOutputEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.passedThreshold ? "checkmark.circle.fill" : "circle.dotted")
                .font(.caption2)
                .foregroundStyle(entry.passedThreshold ? Color.green : Color.secondary)
            Text(entry.birdName)
                .font(.caption)
                .foregroundStyle(entry.passedThreshold ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(String(format: "%.1f%%", entry.confidence * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(entry.passedThreshold ? .primary : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: "%@, %.1f percent, %@ threshold",
                entry.birdName,
                entry.confidence * 100,
                entry.passedThreshold ? "above" : "below"
            )
        )
    }

    /// Species mode dedupes the whole session by species (unique-first, most
    /// recent on top); Timeline mode keeps the chronological run grouping.
    private var detectionGroups: [DetectionGroup] {
        switch detectionMode {
        case .timeline:
            return DetectionGroup.grouped(viewModel.detections)
        case .species:
            let bySpecies = Dictionary(grouping: viewModel.detections, by: { $0.birdId })
            return bySpecies.values
                .map { DetectionGroup(detections: $0.sorted { $0.timestamp > $1.timestamp }) }
                .sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    private var spectrogramMarkers: [SpectrogramView.Marker] {
        let history = TimeInterval(audioHandler.spectrogram?.historySeconds ?? SpectrogramEngine.historySeconds)
        let cutoff = Date().addingTimeInterval(-history)
        return viewModel.detections
            .filter { $0.source == .live && $0.timestamp >= cutoff }
            .map { SpectrogramView.Marker(id: $0.id, timestamp: $0.timestamp, label: $0.birdName) }
    }

    private func disclosureLabel(_ title: String, summary: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var tuningSummary: String {
        "gain +\(Int(settings.inputGainDB)) dB · threshold \(Int(settings.confidenceThreshold * 100))%"
    }

    private var statsSummary: String {
        guard viewModel.isListening else { return "idle" }
        let stats = viewModel.recognitionStats
        var parts: [String] = [stats.isBehindRealtime ? "behind" : "on pace"]
        if let ms = stats.lastInferenceMs {
            parts.append("\(ms) ms")
        }
        if stats.silentWindowsSkipped > 0 {
            parts.append("silent \(stats.silentWindowsSkipped)")
        }
        return parts.joined(separator: " · ")
    }

    private var debugSummary: String {
        let log = viewModel.modelOutputLog
        guard !log.isEmpty else {
            return debugExpanded ? (viewModel.isListening ? "capturing…" : "idle") : "off"
        }
        let passed = log.filter(\.passedThreshold).count
        return "\(log.count) rows · \(passed) ≥ threshold"
    }

    private var levelMeter: some View {
        HStack(spacing: 8) {
            Text("Level")
                .font(.caption)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(.quaternary)
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(viewModel.isListening ? Color.green : Color.secondary)
                            .frame(width: proxy.size.width * CGFloat(min(1, max(0, audioHandler.level))))
                    }
                }
            Text(String(format: "%.0f dB", viewModel.meterStats.peakDB))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "Input level %.0f decibels peak", viewModel.meterStats.peakDB))
    }

    private var sensitivityControl: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            if settings.autoGainEnabled {
                Text("Auto-gain sets the final level for inference. Sensitivity still drives the meter, spectrogram, and silence gate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: settings.inputGainDB) { _, gain in
            audioHandler.setInputGain(dB: gain)
        }
    }

    // MARK: detections column

    private var detectionsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(detectionMode == .species ? "Species this session" : "Detections")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    viewModel.clearRecentDetections()
                }
                .font(.caption)
                .disabled(viewModel.detections.isEmpty)
            }

            Picker("View", selection: $detectionMode) {
                Text("Species").tag(DetectionListMode.species)
                Text("Timeline").tag(DetectionListMode.timeline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if viewModel.isListening, viewModel.recognitionStats.belowThresholdCount > 0 {
                Button {
                    withAnimation { debugExpanded = true }
                } label: {
                    Text("\(viewModel.recognitionStats.belowThresholdCount) below threshold — see Debug")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show the live model output, including detections below your threshold")
            }

            if viewModel.detections.isEmpty {
                setupChecklist
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(detectionGroups) { group in
                            DetectionCardView(
                                group: group,
                                lifetimeCount: viewModel.historyStore.lifetimeCount(for: group.representative.birdId),
                                isIgnored: viewModel.isIgnored(group.representative),
                                onIgnore: { viewModel.ignore(detection: group.representative) },
                                onDelete: { viewModel.deleteDetections(in: group) },
                                onSubmit: { viewModel.submitToEBirdSheet(for: group.strongest) },
                                onOpenInfo: { viewModel.openEBirdInfo(for: group.representative) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 9) {
            checklistRow(
                done: audioHandler.permissionGranted,
                failed: audioHandler.isPermissionDenied,
                doneText: "Microphone access granted",
                pendingText: "Waiting for microphone access",
                failedText: "Microphone access denied — enable it in System Settings → Privacy & Security"
            )
            checklistRow(
                done: viewModel.modelState == .ready,
                failed: viewModel.modelState.isFailedState,
                doneText: "BirdNET model loaded",
                pendingText: "Loading BirdNET model…",
                failedText: "Model failed to load — use Reload Model above"
            )
            checklistRow(
                done: viewModel.isListening,
                failed: false,
                doneText: "Listening to the microphone",
                pendingText: "Not listening — press Start Listening",
                failedText: ""
            )
            if audioHandler.permissionGranted, viewModel.modelState == .ready, viewModel.isListening {
                Label("Waiting for the first bird…", systemImage: "ear")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func checklistRow(
        done: Bool,
        failed: Bool,
        doneText: String,
        pendingText: String,
        failedText: String
    ) -> some View {
        let symbol = done ? "checkmark.circle.fill" : (failed ? "exclamationmark.circle.fill" : "circle")
        let color: Color = done ? .green : (failed ? .red : .secondary)
        let text = done ? doneText : (failed ? failedText : pendingText)
        return Label {
            Text(text)
                .font(.callout)
                .foregroundStyle(done ? .primary : .secondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }
}

extension BirdNetCoreMLRecognizer.State {
    var isFailedState: Bool {
        if case .failed = self { return true }
        return false
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
                Text("Session species list")
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
