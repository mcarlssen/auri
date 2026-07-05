import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject private var audioHandler: AudioHandler

    init(viewModel: BirdDetectionViewModel) {
        self.viewModel = viewModel
        self.audioHandler = viewModel.audioHandler
    }

    /// Most-recent detections deduped by species, so the popover surfaces
    /// unique birds rather than repeats of the same one.
    private var recentDetections: [BirdDetection] {
        var seen = Set<Int>()
        var result: [BirdDetection] = []
        for detection in viewModel.detections where seen.insert(detection.birdId).inserted {
            result.append(detection)
            if result.count == 3 { break }
        }
        return result
    }

    private var sessionSpeciesCount: Int {
        viewModel.sessionSpecies.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ListenStatusPill(viewModel: viewModel)

            if viewModel.isListening {
                levelBar
            }

            Divider()

            if recentDetections.isEmpty {
                Text(viewModel.isListening ? "Listening — no birds yet." : "Start listening to identify birds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("\(sessionSpeciesCount) species this session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 4) {
                    ForEach(recentDetections) { detection in
                        detectionRow(detection)
                    }
                }
            }

            Divider()

            Button {
                viewModel.openMainWindow()
            } label: {
                Text("Open Auri")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            Task { await viewModel.bootstrapIfNeeded() }
        }
    }

    private var levelBar: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.green)
                        .frame(width: proxy.size.width * CGFloat(min(1, max(0, audioHandler.level))))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input level")
    }

    private func detectionRow(_ detection: BirdDetection) -> some View {
        Button {
            viewModel.openMainWindow()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(detection.rarity?.level == .unusual ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(detection.birdName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    (Text(detection.timestamp, style: .relative) + Text(" ago"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(String(format: "%.0f%%", detection.confidence * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(format: "%@, %.0f percent confidence. Opens Auri.", detection.birdName, detection.confidence * 100)
        )
    }
}
