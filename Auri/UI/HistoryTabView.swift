import SwiftUI

struct HistoryTabView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel
    @ObservedObject private var historyStore: RecognitionHistoryStore

    @State private var searchText = ""
    @State private var sortOption: HistorySortOption = .date

    init(viewModel: BirdDetectionViewModel) {
        self.viewModel = viewModel
        self.historyStore = viewModel.historyStore
    }

    private var summaries: [SpeciesHistorySummary] {
        historyStore.speciesSummaries(search: searchText, sort: sortOption)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recognition history")
                .font(.title2.bold())

            Text("Persistent log of all detections across sessions. Search and sort by species.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

                Text("\(historyStore.entries.count) total")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("Clear history", role: .destructive) {
                    historyStore.clear()
                }
                .disabled(historyStore.entries.isEmpty)
            }

            if summaries.isEmpty {
                Text(searchText.isEmpty ? "No recognitions recorded yet." : "No species match your search.")
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
                    onIgnore: { viewModel.ignore(detection: detection) },
                    onDelete: { viewModel.deleteDetection(detection) },
                    onSubmit: { viewModel.submitToEBirdSheet(for: detection) }
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("🐦 \(summary.birdName)")
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(summary.totalCount)")
                            .font(.title3.monospacedDigit().bold())
                        Text("lifetime")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(summary.scientificName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(summary.lastSeen.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if summary.totalCount > 1 {
                        Text("First: \(summary.firstSeen.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let rarity = summary.rarity {
                        Text(rarity.displayLabel)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(rarityBackground(rarity), in: Capsule())
                    }

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func rarityBackground(_ rarity: RarityInfo) -> Color {
        switch rarity.level {
        case .unusual: return .orange.opacity(0.25)
        case .expected: return .green.opacity(0.2)
        case .unknown: return .secondary.opacity(0.15)
        }
    }
}
