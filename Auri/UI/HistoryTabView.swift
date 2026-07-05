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
    @AppStorage("expectedNearbyExpanded") private var expectedNearbyExpanded = false
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

            if scope == .lifetime, !viewModel.expectedNearby.isEmpty {
                expectedNearbySection
            }

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

    private var expectedNearbySection: some View {
        DisclosureGroup(isExpanded: $expectedNearbyExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.expectedNearby, id: \.scientificName) { observation in
                    expectedNearbyRow(observation)
                }
                Text(expectedNearbyFooterText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Image(systemName: "binoculars")
                Text("Heard nearby — not yet on your list")
                Spacer()
                Text("\(viewModel.expectedNearby.count) species")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func expectedNearbyRow(_ observation: NearbyObservation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(observation.commonName)
                    .font(.subheadline)
                Text(displayScientificName(observation.scientificName))
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let observedAt = observation.lastObservedAt {
                Text("seen nearby \(observedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.openEBirdInfo(scientificName: observation.scientificName)
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("View \(observation.commonName) on eBird")
            .accessibilityLabel("View \(observation.commonName) on eBird")
        }
    }

    private var expectedNearbyFooterText: String {
        if let region = viewModel.regionalLabel, !region.isEmpty {
            return "Reported to eBird in region \(region) within the last 14 days."
        }
        return "Reported to eBird within the last 14 days."
    }

    /// eBird nearby names are stored lowercased for matching; show the binomial
    /// with a capitalized genus so it reads like the app's other species names.
    private func displayScientificName(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}

struct SpeciesHistoryCard: View {
    let summary: SpeciesHistorySummary
    let entries: [BirdDetection]
    @ObservedObject var viewModel: BirdDetectionViewModel

    var body: some View {
        DisclosureGroup {
            SpeciesInfoView(scientificName: summary.scientificName)
                .padding(.bottom, 4)
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
