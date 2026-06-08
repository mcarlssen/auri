import SwiftUI

struct DetectionCardView: View {
    let detection: BirdDetection
    let isIgnored: Bool
    let onIgnore: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🐦 \(detection.birdName)")
                    .font(.headline)
                Spacer()
                Text(detection.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(detection.scientificName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text(String(format: "%.0f%% confidence", detection.confidence * 100))
                    .font(.caption)
                Spacer()
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
}
