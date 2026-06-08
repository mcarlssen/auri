import AppKit
import SwiftUI

struct SpectrogramView: View {
    let snapshot: SpectrogramEngine.Snapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            frequencyAxis
            VStack(alignment: .leading, spacing: 4) {
                spectrogramImage
                timeAxis
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }

    private var spectrogramImage: some View {
        SpectrogramImageHost(snapshot: snapshot)
            .frame(maxWidth: .infinity)
            .frame(height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(0.08))
            }
    }

    private var frequencyAxis: some View {
        let labels = frequencyAxisLabels
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                if index > 0 {
                    Spacer()
                }
                axisLabel(label)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 236)
    }

    private var frequencyAxisLabels: [String] {
        guard let snapshot else {
            return ["10k", "1k", "100", "20"]
        }

        let tickCount = 4
        let minF = snapshot.minFrequency
        let maxF = snapshot.maxFrequency

        return (0..<tickCount).map { index in
            let fraction = Float(tickCount - 1 - index) / Float(max(tickCount - 1, 1))
            let frequency = snapshot.frequencyScale.frequency(
                atPosition: fraction,
                minHz: minF,
                maxHz: maxF
            )
            return Self.formatFrequency(frequency)
        }
    }

    private var timeAxis: some View {
        let history = snapshot?.historySeconds ?? 5
        let mid = history / 2
        return HStack {
            axisLabel(String(format: "-%.0fs", history))
            Spacer()
            axisLabel(String(format: "-%.0fs", mid))
            Spacer()
            axisLabel("now")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
    }

    private static func formatFrequency(_ hz: Float) -> String {
        if hz >= 10_000 {
            return String(format: "%.0fk", hz / 1000)
        }
        if hz >= 1000 {
            let value = hz / 1000
            return value >= 10 ? String(format: "%.0fk", value) : String(format: "%.1fk", value)
        }
        return String(format: "%.0f", hz)
    }
}

private struct SpectrogramImageHost: NSViewRepresentable {
    let snapshot: SpectrogramEngine.Snapshot?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.imageAlignment = .alignBottomRight
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard let snapshot else {
            nsView.image = nil
            return
        }
        let size = NSSize(width: snapshot.width, height: snapshot.height)
        let image = NSImage(cgImage: snapshot.cgImage, size: size)
        image.isTemplate = false
        nsView.image = image
    }
}
