import SwiftUI
import UniformTypeIdentifiers

struct OfflineAnalysisTabView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @State private var showingFileImporter = false

    private var fileDetections: [BirdDetection] {
        viewModel.detections.filter { $0.source == .file }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Analyze a recording")
                .font(.title2.bold())

            Text(
                "Analyze a saved recording when birds are quiet outside. " +
                "Per-species cooldown applies along the audio timeline — " +
                "with a 1-hour cooldown, a 90-minute file allows up to two qualifying detections per species."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Analyze audio file…") {
                    showingFileImporter = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isAnalyzingFile || viewModel.modelState != .ready)

                if viewModel.isAnalyzingFile {
                    Button("Cancel", role: .cancel) {
                        viewModel.cancelFileAnalysis()
                    }
                }
            }

            analysisStatus

            if !fileDetections.isEmpty {
                Text("File detections")
                    .font(.headline)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(fileDetections) { detection in
                            DetectionCardView(
                                detection: detection,
                                lifetimeCount: viewModel.historyStore.lifetimeCount(for: detection.birdId),
                                isIgnored: viewModel.isIgnored(detection),
                                onIgnore: { viewModel.ignore(detection: detection) },
                                onDelete: { viewModel.deleteDetection(detection) },
                                onSubmit: { viewModel.submitToEBirdSheet(for: detection) },
                                onOpenInfo: { viewModel.openEBirdInfo(for: detection) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else if !viewModel.isAnalyzingFile {
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                viewModel.analyzeAudioFile(at: url)
            case .failure:
                break
            }
        }
    }

    @ViewBuilder
    private var analysisStatus: some View {
        switch viewModel.fileAnalysisState {
        case .idle:
            Text("Select a WAV, MP3, M4A, or other audio file to run BirdNET offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running(let fileName, let progress, let windows, let found):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("Analyzing \(fileName): window \(windows), \(found) qualifying detection\(found == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .completed(let fileName, let windows, let found):
            Text("Finished \(fileName): \(windows) windows, \(found) qualifying detection\(found == 1 ? "" : "s").")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
