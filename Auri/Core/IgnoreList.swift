import Foundation

struct IgnoreList {
    var speciesIDs: Set<Int>
    var speciesNames: Set<String>

    func isSpeciesIgnored(birdId: Int, birdName: String) -> Bool {
        speciesIDs.contains(birdId) || speciesNames.contains(birdName)
    }
}
