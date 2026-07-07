import Foundation

/// One recent eBird report of a species near the user.
struct NearbyObservation: Sendable, Equatable {
    let commonName: String
    let scientificName: String        // stored lowercased for matching
    let lastObservedAt: Date?
    let locationName: String?
}

/// Turns the raw "recently reported near you" eBird feed into the anticipation
/// list — species being seen nearby that the user has not recorded themselves.
///
/// This lives here rather than in `EBirdRegionalService` because the service is
/// not part of the AuriCore SPM package; declaring the model and the pure diff
/// together keeps both testable without the network or the actor.
enum ExpectedNearbyBuilder {
    /// Nearby-reported species the user has not heard, newest sighting first.
    ///
    /// - `heardScientificNames`: names the user has recorded, already lowercased
    ///   by the caller; the observation side is lowercased here so matching is
    ///   case-insensitive regardless of how eBird cased the source name.
    /// - `ignoredSpeciesNames`: common names exactly as `Settings` stores them,
    ///   matched against `commonName` case-insensitively.
    /// - `limit`: caps the result. Duplicate species in `nearby` are tolerated
    ///   and pass through — deduplication is the service's responsibility.
    static func expected(
        nearby: [NearbyObservation],
        heardScientificNames: Set<String>,
        ignoredSpeciesNames: Set<String>,
        limit: Int = 25
    ) -> [NearbyObservation] {
        let ignoredLowercased = Set(ignoredSpeciesNames.map { $0.lowercased() })
        let unheard = nearby.filter { observation in
            if heardScientificNames.contains(observation.scientificName.lowercased()) {
                return false
            }
            if ignoredLowercased.contains(observation.commonName.lowercased()) {
                return false
            }
            return true
        }

        // Newest sighting first; observations without a parseable date sort last
        // so the freshest, most actionable reports lead.
        let sorted = unheard.sorted { left, right in
            switch (left.lastObservedAt, right.lastObservedAt) {
            case let (leftDate?, rightDate?):
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }

        return Array(sorted.prefix(max(0, limit)))
    }
}
