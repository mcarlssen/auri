import SwiftUI

struct IgnoreListSettingsView: View {
    @ObservedObject var settings: AppSettings
    let species: [Bird]

    @State private var searchText = ""
    @State private var selectedBirdID = 0
    @State private var manualSpeciesName = ""

    private var addableBirds: [Bird] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return species
            .filter { !settings.ignoredSpeciesNames.contains($0.commonName) }
            .filter { bird in
                guard !query.isEmpty else { return true }
                return bird.commonName.localizedCaseInsensitiveContains(query)
                    || bird.scientificName.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.commonName.localizedCaseInsensitiveCompare($1.commonName) == .orderedAscending }
            .prefix(200)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mute a species")
                .font(.subheadline.weight(.semibold))

            if species.isEmpty {
                Text("BirdNET species search loads when the model is ready. You can still add species by name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Bird name", text: $manualSpeciesName)
                    Button("Add") {
                        settings.ignore(speciesName: manualSpeciesName)
                        manualSpeciesName = ""
                    }
                    .disabled(manualSpeciesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                TextField("Search species", text: $searchText)

                Picker("Species", selection: $selectedBirdID) {
                    Text("Select species").tag(0)
                    ForEach(addableBirds) { bird in
                        Text(bird.commonName).tag(bird.id)
                    }
                }

                Button("Mute") {
                    guard let bird = species.first(where: { $0.id == selectedBirdID }) else { return }
                    settings.ignore(bird: bird)
                    selectedBirdID = 0
                    searchText = ""
                }
                .disabled(selectedBirdID == 0)
            }
        }
    }
}
