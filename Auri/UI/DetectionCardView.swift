import SwiftUI

struct DetectionCardView: View {
    let detection: BirdDetection
    let lifetimeCount: Int?
    let isIgnored: Bool
    let onIgnore: () -> Void
    let onDelete: () -> Void
    let onSubmit: () -> Void

    init(
        detection: BirdDetection,
        lifetimeCount: Int? = nil,
        isIgnored: Bool,
        onIgnore: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSubmit: @escaping () -> Void
    ) {
        self.detection = detection
        self.lifetimeCount = lifetimeCount
        self.isIgnored = isIgnored
        self.onIgnore = onIgnore
        self.onDelete = onDelete
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🐦 \(detection.birdName)")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(detection.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if detection.source == .file, let offset = detection.audioOffsetSeconds {
                        Text("File @ \(formatOffset(offset))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(detection.scientificName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(String(format: "%.0f%% confidence", detection.confidence * 100))
                    .font(.caption)

                if let lifetimeCount, lifetimeCount > 1 {
                    Text("· \(lifetimeCount) lifetime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let rarity = detection.rarity {
                    Text("· \(rarity.displayLabel)")
                        .font(.caption)
                        .foregroundStyle(rarity.level == .unusual ? .orange : .secondary)
                }

                Spacer()
            }

            HStack {
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Ignore", action: onIgnore)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isIgnored)
                Button("Submit to eBird", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatOffset(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
