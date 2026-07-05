import XCTest
@testable import AuriCore

final class ExpectedNearbyBuilderTests: XCTestCase {
    private func observation(
        common: String,
        scientific: String,
        observedAt: Date? = nil,
        location: String? = nil
    ) -> NearbyObservation {
        NearbyObservation(
            commonName: common,
            scientificName: scientific,
            lastObservedAt: observedAt,
            locationName: location
        )
    }

    func testExcludesHeardSpeciesCaseInsensitively() {
        // The observation carries a mixed-case scientific name while the heard
        // set is lowercased (as the ViewModel supplies it); the builder must
        // still exclude the match by lowercasing the observation side.
        let nearby = [
            observation(common: "American Robin", scientific: "Turdus Migratorius"),
            observation(common: "Song Sparrow", scientific: "melospiza melodia"),
        ]
        let result = ExpectedNearbyBuilder.expected(
            nearby: nearby,
            heardScientificNames: ["turdus migratorius"],
            ignoredSpeciesNames: []
        )
        XCTAssertEqual(result.map(\.commonName), ["Song Sparrow"])
    }

    func testExcludesIgnoredCommonNamesCaseInsensitively() {
        let nearby = [
            observation(common: "European Starling", scientific: "sturnus vulgaris"),
            observation(common: "Song Sparrow", scientific: "melospiza melodia"),
        ]
        let result = ExpectedNearbyBuilder.expected(
            nearby: nearby,
            heardScientificNames: [],
            ignoredSpeciesNames: ["EUROPEAN STARLING"]
        )
        XCTAssertEqual(result.map(\.commonName), ["Song Sparrow"])
    }

    func testSortsNewestFirstWithNilDatesLast() {
        let now = Date()
        let nearby = [
            observation(common: "No Date", scientific: "aaa aaa", observedAt: nil),
            observation(common: "Older", scientific: "bbb bbb", observedAt: now.addingTimeInterval(-3600)),
            observation(common: "Newest", scientific: "ccc ccc", observedAt: now),
        ]
        let result = ExpectedNearbyBuilder.expected(
            nearby: nearby,
            heardScientificNames: [],
            ignoredSpeciesNames: []
        )
        XCTAssertEqual(result.map(\.commonName), ["Newest", "Older", "No Date"])
    }

    func testRespectsLimit() {
        let now = Date()
        let nearby = (0..<10).map { index in
            observation(
                common: "Species \(index)",
                scientific: "sci \(index)",
                observedAt: now.addingTimeInterval(Double(-index))
            )
        }
        let result = ExpectedNearbyBuilder.expected(
            nearby: nearby,
            heardScientificNames: [],
            ignoredSpeciesNames: [],
            limit: 3
        )
        // Newest three (offsets 0, -1, -2 seconds) survive the cap, in order.
        XCTAssertEqual(result.map(\.commonName), ["Species 0", "Species 1", "Species 2"])
    }

    func testToleratesDuplicateInputRows() {
        let now = Date()
        let nearby = [
            observation(common: "American Robin", scientific: "turdus migratorius", observedAt: now),
            observation(common: "American Robin", scientific: "turdus migratorius", observedAt: now.addingTimeInterval(-60)),
        ]
        // Deduplication is the service's job; the builder passes duplicates
        // through without crashing or dropping either row.
        let result = ExpectedNearbyBuilder.expected(
            nearby: nearby,
            heardScientificNames: [],
            ignoredSpeciesNames: []
        )
        XCTAssertEqual(result.count, 2)
    }
}
