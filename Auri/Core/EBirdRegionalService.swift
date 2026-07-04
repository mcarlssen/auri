import CoreLocation
import Foundation

/// Uses the eBird API to determine whether a species is expected at the user's location.
/// Requires a free API key from https://ebird.org/api/keygen
actor EBirdRegionalService {
    static let shared = EBirdRegionalService()

    private var regionalSpeciesCodes: Set<String> = []
    private var regionLabel: String?
    private var lastRefreshLocation: CLLocation?
    private var sciNameToCode: [String: String] = [:]

    func currentRegionLabel() -> String? {
        regionLabel
    }

    func refreshIfNeeded(location: CLLocation, apiKey: String) async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        if let last = lastRefreshLocation, last.distance(from: location) < 5_000, !regionalSpeciesCodes.isEmpty {
            return
        }

        guard let regionCode = await nearestRegionCode(location: location, apiKey: trimmedKey) else {
            return
        }

        guard let speciesCodes = await fetchRegionalSpecies(regionCode: regionCode, apiKey: trimmedKey) else {
            return
        }

        regionalSpeciesCodes = Set(speciesCodes)
        regionLabel = regionCode
        lastRefreshLocation = location
    }

    func rarity(for scientificName: String, apiKey: String) async -> RarityInfo {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return RarityInfo(level: .unknown, regionLabel: nil, frequencyPercent: nil)
        }

        guard let speciesCode = await speciesCode(for: scientificName, apiKey: trimmedKey) else {
            return RarityInfo(level: .unknown, regionLabel: regionLabel, frequencyPercent: nil)
        }

        if regionalSpeciesCodes.isEmpty {
            return RarityInfo(level: .unknown, regionLabel: regionLabel, frequencyPercent: nil)
        }

        if regionalSpeciesCodes.contains(speciesCode) {
            return RarityInfo(level: .expected, regionLabel: regionLabel, frequencyPercent: nil)
        }

        return RarityInfo(level: .unusual, regionLabel: regionLabel, frequencyPercent: nil)
    }

    /// Public resolver for the eBird 6-letter species code, used to link to a
    /// species' eBird page. Returns nil without a key or when the lookup fails.
    func eBirdSpeciesCode(for scientificName: String, apiKey: String) async -> String? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return await speciesCode(for: scientificName, apiKey: trimmedKey)
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
