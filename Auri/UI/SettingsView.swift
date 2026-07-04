import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var locationProvider: LocationProvider
    var embedded: Bool = false

    @State private var devices: [AVCaptureDevice] = []
    @State private var launchAtLoginError: String?
    @State private var advancedDetectionExpanded = false

    init(viewModel: BirdDetectionViewModel, embedded: Bool = false) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
        self.locationProvider = viewModel.locationProvider
        self.embedded = embedded
    }

    var body: some View {
        ScrollView {
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                        .onChange(of: settings.launchAtLogin) { _, enabled in
                            applyLaunchAtLogin(enabled)
                        }

                    Toggle("Start listening at login", isOn: $settings.startListeningAtLogin)

                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Listening") {
                    Picker("Input source", selection: $settings.audioInputSource) {
                        ForEach(AudioInputSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .onChange(of: settings.audioInputSource) { _, _ in
                        Task { await viewModel.refreshRuntime() }
                    }

                    if settings.audioInputSource == .selectedDevice {
                        Picker("Device", selection: $settings.selectedDeviceUID) {
                            ForEach(devices, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(device.uniqueID)
                            }
                        }
                        .onChange(of: settings.selectedDeviceUID) { _, _ in
                            Task { await viewModel.refreshRuntime() }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sensitivity: +\(Int(settings.inputGainDB)) dB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.inputGainDB, in: 0...36, step: 1)
                        if settings.autoGainEnabled {
                            Text("Auto-gain sets the final level for inference, so this has little effect there. Sensitivity still drives the input meter, the spectrogram, and the silence gate.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .onChange(of: settings.inputGainDB) { _, gain in
                        viewModel.audioHandler.setInputGain(dB: gain)
                    }

                    Picker("Spectrogram scale", selection: $settings.spectrogramFrequencyScale) {
                        ForEach(SpectrogramFrequencyScale.allCases) { scale in
                            Text(scale.label).tag(scale)
                        }
                    }
                    .onChange(of: settings.spectrogramFrequencyScale) { _, _ in
                        viewModel.reconfigureSpectrogram()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spectrogram min frequency: \(Int(settings.spectrogramMinFrequency)) Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.spectrogramMinFrequency, in: 20...5000, step: 10)
                    }
                    .onChange(of: settings.spectrogramMinFrequency) { _, _ in
                        viewModel.reconfigureSpectrogram()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spectrogram max frequency: \(Int(settings.spectrogramMaxFrequency)) Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.spectrogramMaxFrequency, in: 500...20_000, step: 100)
                    }
                    .onChange(of: settings.spectrogramMaxFrequency) { _, _ in
                        viewModel.reconfigureSpectrogram()
                    }

                    Text("Spectrogram display uses a 1024-point FFT at 512×192; the Mel scale matches birdsong perception. BirdNET analysis is unaffected by spectrogram settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Detection") {
                    ConfidenceThresholdControls(
                        settings: settings,
                        stats: viewModel.recognitionStats,
                        onApplySuggested: viewModel.applySuggestedConfidenceThreshold
                    )

                    Toggle("Auto-gain before inference", isOn: $settings.autoGainEnabled)

                    DisclosureGroup(isExpanded: $advancedDetectionExpanded) {
                        Picker("Window overlap", selection: $settings.detectionOverlap) {
                            ForEach(DetectionOverlap.allCases) { overlap in
                                Text(overlap.label).tag(overlap)
                            }
                        }
                        .onChange(of: settings.detectionOverlap) { _, _ in
                            viewModel.applyDetectionPipelineSettings()
                        }

                        Toggle("Skip silent windows", isOn: $settings.silenceSkipEnabled)
                            .onChange(of: settings.silenceSkipEnabled) { _, _ in
                                viewModel.applySilenceGate()
                            }

                        if settings.silenceSkipEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Silence threshold: \(Int(settings.silenceSkipThresholdDB)) dBFS peak")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $settings.silenceSkipThresholdDB, in: -80 ... -30, step: 1)
                            }
                            .onChange(of: settings.silenceSkipThresholdDB) { _, _ in
                                viewModel.applySilenceGate()
                            }
                        }

                        Text("BirdNET analyzes fixed 3-second windows; overlap controls how often a new window starts. More overlap catches calls that straddle window boundaries and lowers detection latency, at the cost of more inference. The silence gate skips inference when a window's peak level (after sensitivity gain, shown in the Listen meter) stays below the threshold.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        HStack {
                            Text("Advanced")
                            Spacer()
                            Text(advancedDetectionSummary)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Auto-gain normalizes quiet input toward a level BirdNET expects. Without Merlin's metadata model, try a 25–40% threshold or use the suggested value after a minute of listening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
                    Toggle("Only notify for new species", isOn: $settings.notifyNewSpeciesOnly)
                        .disabled(!settings.notificationsEnabled)
                        .help("Notify only the first time a species is heard this session, not on repeats.")
                    Toggle("Play sound", isOn: $settings.notificationSoundEnabled)
                        .disabled(!settings.notificationsEnabled)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Per-species cooldown: \(formatCooldown(settings.perSpeciesCooldownSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.perSpeciesCooldownSeconds, in: 60...86_400, step: 60)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Max notifications per hour: \(settings.maxNotificationsPerHour)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(settings.maxNotificationsPerHour) },
                                set: { settings.maxNotificationsPerHour = Int($0) }
                            ),
                            in: 5...100,
                            step: 5
                        )
                    }
                }

                Section("Location & rarity") {
                    Toggle("Use location for regional filtering", isOn: $settings.locationFilteringEnabled)
                        .onChange(of: settings.locationFilteringEnabled) { _, _ in
                            viewModel.syncLocationAccess()
                        }

                    LocationStatusView(
                        isEnabled: settings.locationFilteringEnabled,
                        location: locationProvider.lastKnownLocation,
                        authorizationStatus: locationProvider.authorizationStatus,
                        regionalLabel: viewModel.regionalLabel,
                        hasEBirdKey: !settings.resolvedEBirdApiKey.isEmpty
                    )

                    SecureField("eBird API key", text: $settings.eBirdApiKey)

                    Text("BirdNET's audio model does not accept location input. When enabled, Auri uses your location and eBird regional checklists to filter out-of-range false positives. A species not expected in your area is hidden unless it scores at least \(Int(BirdDetectionViewModel.unusualSpeciesConfidenceFloor * 100))% confidence; expected species are unaffected. Regional filtering needs a free API key from ebird.org/api/keygen — without one it has no effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    EBirdAttributionView()
                }

                Section("Muted species") {
                    if mutedNames.isEmpty {
                        Text("No muted species yet. Mute a species from any detection's hover actions or right-click menu, or add one below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mutedNames, id: \.self) { name in
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
                                Button("Unmute") {
                                    settings.unignore(speciesName: name, matchingSpecies: viewModel.species)
                                    viewModel.objectWillChange.send()
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    IgnoreListSettingsView(settings: settings, species: viewModel.species)
                }

                Section("Developer") {
                    Toggle("Debug logging", isOn: $settings.debugLogging)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            loadDevices()
            settings.launchAtLogin = LaunchAtLoginManager.isEnabled
            viewModel.syncLocationAccess()
        }
        .task {
            await viewModel.reloadSpeciesIfNeeded()
        }
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var advancedDetectionSummary: String {
        let gate = settings.silenceSkipEnabled
            ? "gate \(Int(settings.silenceSkipThresholdDB)) dBFS"
            : "gate off"
        return "\(settings.detectionOverlap.label) · \(gate)"
    }

    private var mutedNames: [String] {
        settings.ignoredSpeciesNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func formatCooldown(_ seconds: Double) -> String {
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(Int(seconds)) seconds"
    }

    private func loadDevices() {
        devices = AudioHandler.availableDevices()
        if settings.selectedDeviceUID.isEmpty {
            settings.selectedDeviceUID = devices.first?.uniqueID ?? ""
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            settings.launchAtLogin = LaunchAtLoginManager.isEnabled
        }
    }
}
