import SwiftUI

struct ConfidenceThresholdControls: View {
    @ObservedObject var settings: AppSettings
    let stats: RecognitionPipelineStats
    var onApplySuggested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Slider(value: $settings.confidenceThreshold, in: 0...1, step: 0.05) {
                Text("Confidence threshold")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(String(format: "Threshold %.0f%%", settings.confidenceThreshold * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let average = stats.rollingAverageTopConfidence {
                    Text(String(format: "· 30s avg top %.0f%%", average * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let autoGain = stats.lastAutoGainDB {
                    Text(String(format: "· auto +%.0f dB", autoGain))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let suggested = stats.suggestedConfidenceThreshold {
                HStack(spacing: 8) {
                    Text(String(format: "Suggested %.0f%%", suggested * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Apply") {
                        onApplySuggested()
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
        }
    }
}
