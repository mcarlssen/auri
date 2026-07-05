import CoreLocation
import Foundation

private func RegionLog(_ message: @autoclosure () -> String) {
    RecognitionLogger.log(message(), category: "Location")
}

/// Uses the eBird API to determine whether a species is expected at the user's location.
/// Requires a free API key from https://ebird.org/api/keygen
actor EBirdRegionalService {
    static let shared = EBirdRegionalService()

    /// A snapshot of the current regional data, handed to the main actor so
    /// detections and the live model-output feed can be range-filtered synchronously.
    struct RegionalSnapshot: Sendable {
        let regionLabel: String?
        /// Lowercased scientific names expected in the current region.
        let inRegionScientificNames: Set<String>
        /// Lowercased scientific names known to the eBird taxonomy. A name absent
        /// here can't be judged in/out of region (e.g. a BirdNET label that doesn't
        /// map to an eBird species), so callers must not filter it.
        let knownScientificNames: Set<String>
    }

    private var regionLabel: String?
    private var lastRefreshLocation: CLLocation?
    private var sciNameToCode: [String: String] = [:]

    /// Full eBird taxonomy, loaded once (it is region-independent): maps species
    /// code → lowercased scientific name, alongside the set of all scientific names.
    private var taxonomyCodeToScientific: [String: String] = [:]
    private var taxonomyScientificNames: Set<String> = []

    /// Lowercased scientific names expected in the current region, derived by
    /// intersecting the regional species-code list with the taxonomy.
    private var regionalScientificNames: Set<String> = []

    /// Cache for the "recently reported near you" feed powering the expected-nearby
    /// list. Kept on its own coarse TTL because recent sightings change slowly
    /// while the caller polls often, so refetching every poll would be wasteful.
    private var nearbyObservations: [NearbyObservation] = []
    private var lastNearbyRefreshAt: Date?
    private var lastNearbyRegion: String?

    func currentRegionLabel() -> String? {
        regionLabel
    }

    func regionalSnapshot() -> RegionalSnapshot {
        RegionalSnapshot(
            regionLabel: regionLabel,
            inRegionScientificNames: regionalScientificNames,
            knownScientificNames: taxonomyScientificNames
        )
    }

    func refreshIfNeeded(location: CLLocation, apiKey: String) async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        if let last = lastRefreshLocation, last.distance(from: location) < 5_000, !regionalScientificNames.isEmpty {
            return
        }

        guard let regionCode = await nearestRegionCode(location: location, apiKey: trimmedKey) else {
            RegionLog("could not resolve region for location; skipping refresh")
            return
        }

        guard let speciesCodes = await fetchRegionalSpecies(regionCode: regionCode, apiKey: trimmedKey) else {
            RegionLog("region \(regionCode): failed to fetch species list")
            return
        }

        await loadTaxonomyIfNeeded(apiKey: trimmedKey)
        regionalScientificNames = Set(speciesCodes.compactMap { taxonomyCodeToScientific[$0] })
        regionLabel = regionCode
        lastRefreshLocation = location
        RegionLog("region \(regionCode): \(speciesCodes.count) species codes, \(regionalScientificNames.count) matched to taxonomy")
    }

    /// Species reported to eBird near the user within the last 14 days,
    /// deduplicated by scientific name. Returns the cache when it is fresh and
    /// refreshes it only when empty, older than `maxAgeHours`, or the resolved
    /// region changed — the TTL keeps the frequently-polling expected-nearby loop
    /// from hammering the endpoint.
    ///
    /// Region resolution is owned by `refreshIfNeeded`, so this returns `[]` until
    /// a region has been resolved, and `[]` without a usable API key. On a failed
    /// refresh the previous cache is returned unchanged so a transient error does
    /// not blank the list.
    func nearbySnapshot(apiKey: String, maxAgeHours: Double = 6) async -> [NearbyObservation] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return [] }
        guard let regionCode = regionLabel else { return [] }

        let regionChanged = lastNearbyRegion != regionCode
        let isStale: Bool
        if let last = lastNearbyRefreshAt {
            isStale = Date().timeIntervalSince(last) > maxAgeHours * 3600
        } else {
            isStale = true
        }
        if !regionChanged, !isStale, !nearbyObservations.isEmpty {
            return nearbyObservations
        }

        guard let observations = await fetchNearbyObservations(regionCode: regionCode, apiKey: trimmedKey) else {
            RegionLog("region \(regionCode): failed to fetch recent nearby observations")
            return nearbyObservations
        }

        nearbyObservations = observations
        lastNearbyRefreshAt = Date()
        lastNearbyRegion = regionCode
        RegionLog("region \(regionCode): \(observations.count) recent nearby species")
        return nearbyObservations
    }

    /// Public resolver for the eBird 6-letter species code, used to link to a
    /// species' eBird page. Returns nil without a key or when the lookup fails.
    func eBirdSpeciesCode(for scientificName: String, apiKey: String) async -> String? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return await speciesCode(for: scientificName, apiKey: trimmedKey)
    }

    /// Fetches the full eBird species taxonomy once and caches the code→scientific
    /// mapping. The taxonomy is region-independent, so this runs at most once per
    /// session; later region changes reuse it.
    private func loadTaxonomyIfNeeded(apiKey: String) async {
        guard taxonomyScientificNames.isEmpty else { return }

        var components = URLComponents(string: "https://api.ebird.org/v2/ref/taxonomy/ebird")!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "cat", value: "species"),
        ]
        guard let url = components.url else { return }

        guard let data = await fetch(url: url, apiKey: apiKey),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            RegionLog("failed to load eBird taxonomy")
            return
        }

        var codeToScientific: [String: String] = [:]
        codeToScientific.reserveCapacity(rows.count)
        var scientificNames: Set<String> = []
        scientificNames.reserveCapacity(rows.count)
        for row in rows {
            guard let code = row["speciesCode"] as? String,
                  let scientific = (row["sciName"] as? String)?.lowercased() else {
                continue
            }
            codeToScientific[code] = scientific
            scientificNames.insert(scientific)
        }

        taxonomyCodeToScientific = codeToScientific
        taxonomyScientificNames = scientificNames
        RegionLog("loaded eBird taxonomy: \(scientificNames.count) species")
    }

    private func speciesCode(for scientificName: String, apiKey: String) async -> String? {
        let normalized = scientificName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = sciNameToCode[normalized] {
            return cached
        }

        var components = URLComponents(string: "https://api.ebird.org/v2/ref/taxonomy/ebird")!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "species", value: scientificName),
        ]
        guard let url = components.url else { return nil }

        guard let data = await fetch(url: url, apiKey: apiKey),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let code = first["speciesCode"] as? String else {
            return nil
        }

        sciNameToCode[normalized] = code
        return code
    }

    private func nearestRegionCode(location: CLLocation, apiKey: String) async -> String? {
        var components = URLComponents(string: "https://api.ebird.org/v2/ref/hotspot/geo")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "lng", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "dist", value: "50"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { return nil }

        guard let data = await fetch(url: url, apiKey: apiKey),
              let hotspots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = hotspots.first,
              let countryCode = first["countryCode"] as? String else {
            return countryCodeFallback(location: location)
        }

        if let subnational1 = first["subnational1Code"] as? String, !subnational1.isEmpty {
            return subnational1
        }
        return countryCode
    }

    private func countryCodeFallback(location: CLLocation) -> String? {
        // Rough US bounding box fallback when hotspot lookup fails.
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        if lat >= 24.5, lat <= 49.5, lon >= -125, lon <= -66 {
            return "US"
        }
        return nil
    }

    private func fetchRegionalSpecies(regionCode: String, apiKey: String) async -> [String]? {
        guard let url = URL(string: "https://api.ebird.org/v2/product/spplist/\(regionCode)") else {
            return nil
        }
        guard let data = await fetch(url: url, apiKey: apiKey),
              let codes = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return codes
    }

    private func fetchNearbyObservations(regionCode: String, apiKey: String) async -> [NearbyObservation]? {
        var components = URLComponents(string: "https://api.ebird.org/v2/data/obs/\(regionCode)/recent")
        components?.queryItems = [URLQueryItem(name: "back", value: "14")]
        guard let url = components?.url else { return nil }

        guard let data = await fetch(url: url, apiKey: apiKey),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        // eBird's obsDt is "yyyy-MM-dd HH:mm", but the time is dropped for
        // date-only reports; try the full format first, then the date-only one,
        // and leave the date nil when neither parses.
        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"

        func parseObsDate(_ raw: String?) -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            return dateTimeFormatter.date(from: raw) ?? dateOnlyFormatter.date(from: raw)
        }

        // Deduplicate by scientific name, keeping the most recent sighting; a
        // real date always beats a missing one.
        var latestBySciName: [String: NearbyObservation] = [:]
        for row in rows {
            guard let commonName = row["comName"] as? String,
                  let scientific = (row["sciName"] as? String)?.lowercased() else {
                continue
            }
            let observation = NearbyObservation(
                commonName: commonName,
                scientificName: scientific,
                lastObservedAt: parseObsDate(row["obsDt"] as? String),
                locationName: row["locName"] as? String
            )
            if let existing = latestBySciName[scientific] {
                let keepNew: Bool
                switch (observation.lastObservedAt, existing.lastObservedAt) {
                case let (new?, old?): keepNew = new > old
                case (_?, nil): keepNew = true
                case (nil, _?): keepNew = false
                case (nil, nil): keepNew = false
                }
                if keepNew { latestBySciName[scientific] = observation }
            } else {
                latestBySciName[scientific] = observation
            }
        }
        return Array(latestBySciName.values)
    }

    private func fetch(url: URL, apiKey: String) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-eBirdApiToken")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
