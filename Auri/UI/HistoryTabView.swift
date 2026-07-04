import AppKit
import SwiftUI

/// Time window for the Heard list: the current session, today, or all-time.
enum HeardScope: String, CaseIterable, Identifiable {
    case session
    case today
    case lifetime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "This session"
        case .today: return "Today"
        case .lifetime: return "Lifetime"
        }
    }
}

struct HistoryTabView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject private var historyStore: RecognitionHistoryStore
    @ObservedObject private var settings: AppSettings

    @State private var searchText = ""
    @State private var sortOption: HistorySortOption = .date
    @AppStorage("heardScope") private var scope: HeardScope = .session
    @State private var copyFeedback = ""

    init(viewModel: BirdDetectionViewModel) {
        self.viewModel = viewModel
        self.historyStore = viewModel.historyStore
        self.settings = viewModel.settings
    }

    private var sinceDate: Date? {
        switch scope {
        case .session: return settings.recentClearedAt
        case .today: return Calendar.current.startOfDay(for: Date())
        case .lifetime: return nil
        }
    }

    private var summaries: [SpeciesHistorySummary] {
        historyStore.speciesSummaries(search: searchText, sort: sortOption, since: sinceDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Heard")
                .font(.title2.bold())

            Text("Unique species you've identified, grouped and counted. Switch scope to see this session, today, or your all-time list.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Scope", selection: $scope) {
                ForEach(HeardScope.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                TextField("Search species", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Sort", selection: $sortOption) {
                    ForEach(HistorySortOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Spacer()

                Text("^[\(summaries.count) species](inflect: true)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("Copy list") {
                    copySpeciesList()
                }
                .disabled(summaries.isEmpty)

                if scope == .lifetime {
                    Button("Clear history", role: .destructive) {
                        historyStore.clear()
                    }
                    .disabled(historyStore.entries.isEmpty)
                }
            }

            if !copyFeedback.isEmpty {
                Text(copyFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if summaries.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                Spacer()
                EBirdAttributionView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(summaries) { summary in
                            SpeciesHistoryCard(
                                summary: summary,
                                entries: historyStore.entries(forBirdId: summary.birdId),
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }

                EBirdAttributionView()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyMessage: String {
        if !searchText.isEmpty { return "No species match your search." }
        switch scope {
        case .session: return "No species heard this session yet."
        case .today: return "No species heard today yet."
        case .lifetime: return "No recognitions recorded yet."
        }
    }

    private func copySpeciesList() {
        let lines = summaries.map { "\($0.birdName) (\($0.scientificName))" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copyFeedback = "\(lines.count) species copied to clipboard."
    }
}

struct SpeciesHistoryCard: View {
    let summary: SpeciesHistorySummary
    let entries: [BirdDetection]
    @ObservedObject var viewModel: BirdDetectionViewModel

    var body: some View {
        DisclosureGroup {
            ForEach(entries) { detection in
                DetectionCardView(
                    detection: detection,
                    lifetimeCount: viewModel.historyStore.lifetimeCount(for: detection.birdId),
                    isIgnored: viewModel.isIgnored(detection),
                    timeDisplay: .absolute,
                    onIgnore: { viewModel.ignore(detection: detection) },
                    onDelete: { viewModel.deleteDetection(detection) },
                    onSubmit: { viewModel.submitToEBirdSheet(for: detection) },
                    onOpenInfo: { viewModel.openEBirdInfo(for: detection) }
                )
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.birdName)
                        .font(.headline)
                    Text(summary.scientificName)
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(seenSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let rarity = summary.rarity {
                        Text(rarity.displayLabel)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1.5)
                            .background(rarityBackground(rarity), in: Capsule())
                    }
                }

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(summary.totalCount)")
                        .font(.title3.monospacedDigit().bold())
                    Text("lifetime")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 52, alignment: .trailing)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var seenSummary: String {
        let last = "last \(summary.lastSeen.formatted(date: .abbreviated, time: .shortened))"
        guard summary.totalCount > 1 else { return last }
        return "\(last) · first \(summary.firstSeen.formatted(date: .abbreviated, time: .omitted))"
    }

    private func rarityBackground(_ rarity: RarityInfo) -> Color {
        switch rarity.level {
        case .unusual: return .orange.opacity(0.25)
        case .expected: return .green.opacity(0.2)
        case .unknown: return .secondary.opacity(0.15)
        }
    }
}
