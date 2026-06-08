import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject var settings: AppSettings
    var embedded: Bool = false

    @State private var devices: [AVCaptureDevice] = []
    @State private var launchAtLoginError: String?

    init(viewModel: BirdDetectionViewModel, embedded: Bool = false) {
        self.viewModel = viewModel
        self.settings = viewModel.settings
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

                Section("Recording") {
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
                }

                Section("Spectrogram") {
                    Text("Display uses 1024-point FFT at 512×192. Mel scale matches birdsong perception. BirdNET is unaffected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Frequency scale", selection: $settings.spectrogramFrequencyScale) {
                        ForEach(SpectrogramFrequencyScale.allCases) { scale in
                            Text(scale.label).tag(scale)
                        }
                    }
                    .onChange(of: settings.spectrogramFrequencyScale) { _, _ in
                        viewModel.reconfigureSpectrogram()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Min frequency: \(Int(settings.spectrogramMinFrequency)) Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.spectrogramMinFrequency, in: 20...5000, step: 10)
                    }
                    .onChange(of: settings.spectrogramMinFrequency) { _, _ in
                        viewModel.reconfigureSpectrogram()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Max frequency: \(Int(settings.spectrogramMaxFrequency)) Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.spectrogramMaxFrequency, in: 500...20_000, step: 100)
                    }
                    .onChange(of: settings.spectrogramMaxFrequency) { _, _ in
                        viewModel.reconfigureSpectrogram()
                    }
                }

                Section("Detection") {
                    Slider(value: $settings.confidenceThreshold, in: 0...1, step: 0.05) {
                        Text("Confidence threshold")
                    }
                    Text(String(format: "%.0f%%", settings.confidenceThreshold * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
                    Toggle("Play sound", isOn: $settings.notificationSoundEnabled)
                }

                Section("Developer") {
                    Toggle("Debug logging", isOn: $settings.debugLogging)
                    Button("Inject test detection") {
                        viewModel.injectTestDetection()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            loadDevices()
            settings.launchAtLogin = LaunchAtLoginManager.isEnabled
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
