import Foundation

struct Bird: Identifiable, Codable, Hashable {
    let id: Int
    let commonName: String
    let scientificName: String

    enum CodingKeys: String, CodingKey {
        case id
        case commonName = "common_name"
        case scientificName = "scientific_name"
    }
}
