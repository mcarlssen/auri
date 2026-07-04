import SwiftUI

struct DetectionCardView: View {
    enum TimeDisplay {
        case relative
        case absolute
    }

    let group: DetectionGroup
    let lifetimeCount: Int?
    let isIgnored: Bool
    let timeDisplay: TimeDisplay
    let onIgnore: () -> Void
    let onDelete: () -> Void
    let onSubmit: () -> Void
    let onOpenInfo: () -> Void

    @State private var isHovering = false

    /// The card renders the newest member; confidence reflects the whole run.
    private var detection: BirdDetection { group.representative }

    /// Grouped card for a run of consecutive same-species detections.
    init(
        group: DetectionGroup,
        lifetimeCount: Int? = nil,
        isIgnored: Bool,
        timeDisplay: TimeDisplay = .relative,
        onIgnore: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSubmit: @escaping () -> Void,
        onOpenInfo: @escaping () -> Void = {}
    ) {
        self.group = group
        self.lifetimeCount = lifetimeCount
        self.isIgnored = isIgnored
        self.timeDisplay = timeDisplay
        self.onIgnore = onIgnore
        self.onDelete = onDelete
        self.onSubmit = onSubmit
        self.onOpenInfo = onOpenInfo
    }

    /// Single-detection card (History, file analysis) — wraps one detection.
    init(
        detection: BirdDetection,
        lifetimeCount: Int? = nil,
        isIgnored: Bool,
        timeDisplay: TimeDisplay = .relative,
        onIgnore: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSubmit: @escaping () -> Void,
        onOpenInfo: @escaping () -> Void = {}
    ) {
        self.init(
            group: DetectionGroup(detections: [detection]),
            lifetimeCount: lifetimeCount,
            isIgnored: isIgnored,
            timeDisplay: timeDisplay,
            onIgnore: onIgnore,
            onDelete: onDelete,
            onSubmit: onSubmit,
            onOpenInfo: onOpenInfo
        )
    }

    private var stripeColor: Color {
        detection.rarity?.level == .unusual ? .orange : .green
    }

    private var isUnusual: Bool {
        detection.rarity?.level == .unusual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(detection.birdName)
                    .font(.headline)
                if group.count > 1 {
                    Text("×\(group.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(stripeColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(stripeColor)
                        .help("\(group.count) detections in this run")
                }
                Spacer(minLength: 8)
                timeLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .opacity(isHovering ? 0 : 1)
            }

            Text(detection.scientificName)
                .font(.subheadline.italic())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                confidenceBar
                Text(String(format: "%.0f%%", group.peakConfidence * 100))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .help(group.count > 1 ? "Peak confidence across \(group.count) detections" : "Confidence")

                if let lifetimeCount, lifetimeCount > 1 {
                    Text("\(lifetimeCount) lifetime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let rarity = detection.rarity, rarity.level == .unusual {
                    Text(rarity.displayLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                .fill(stripeColor)
                .frame(width: 4)
        }
        .overlay(alignment: .topTrailing) {
            hoverActions
                .padding(.top, 7)
                .padding(.trailing, 8)
                .opacity(isHovering ? 1 : 0)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("View on eBird", action: onOpenInfo)
            Button("Submit to eBird", action: onSubmit)
            Button("Mute species", action: onIgnore)
                .disabled(isIgnored)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: "View on eBird", onOpenInfo)
        .accessibilityAction(named: "Submit to eBird", onSubmit)
        .accessibilityAction(named: "Mute species", onIgnore)
        .accessibilityAction(named: "Delete", onDelete)
    }

    @ViewBuilder
    private var timeLabel: some View {
        if detection.source == .file, let offset = detection.audioOffsetSeconds {
            Text("File @ \(Self.formatOffset(offset))")
        } else {
            switch timeDisplay {
            case .relative:
                // Auto-updating relative time ("2 min ago") for the live feed.
                Text(detection.timestamp, style: .relative) + Text(" ago")
            case .absolute:
                Text(detection.timestamp.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var confidenceBar: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 110, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(stripeColor)
                    .frame(width: 110 * min(1, max(0, group.peakConfidence)))
            }
            .accessibilityHidden(true)
    }

    private var hoverActions: some View {
        HStack(spacing: 5) {
            cardActionButton(
                systemImage: "info.circle",
                help: "View \(detection.birdName) on eBird",
                action: onOpenInfo
            )
            cardActionButton(
                systemImage: "speaker.slash",
                help: "Mute species",
                action: onIgnore
            )
            .disabled(isIgnored)
            cardActionButton(
                systemImage: "arrow.up.forward.app",
                help: "Submit to eBird",
                action: onSubmit
            )
            cardActionButton(
                systemImage: "trash",
                help: "Delete",
                role: .destructive,
                action: onDelete
            )
        }
    }

    private func cardActionButton(
        systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }

    private var accessibilitySummary: String {
        var parts = [
            detection.birdName,
            String(format: "%.0f percent confidence", group.peakConfidence * 100)
        ]
        if group.count > 1 {
            parts.append("\(group.count) detections")
        }
        if let rarity = detection.rarity, rarity.level == .unusual {
            parts.append("unusual for your area")
        }
        return parts.joined(separator: ", ")
    }

    private static func formatOffset(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
