import AppKit
import SwiftUI

/// Background facts for a species, fetched for the "learn about the birds you
/// heard" experience. Optional and best-effort — everything is nil when offline.
struct SpeciesInfo: Sendable {
    let blurb: String?
    let imageData: Data?
    let pageURL: URL?

    var isEmpty: Bool { blurb == nil && imageData == nil }
}

/// Fetches a short description and thumbnail from Wikipedia's REST summary
/// endpoint by scientific name. Keyless; results (including misses) are cached
/// in memory so a species is only fetched once per session. Fully optional:
/// the app's core identification works offline, this only enriches it.
actor SpeciesEnrichmentService {
    static let shared = SpeciesEnrichmentService()

    private var cache: [String: SpeciesInfo] = [:]
    private var misses: Set<String> = []

    func info(forScientificName scientificName: String) async -> SpeciesInfo? {
        let key = scientificName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached }
        if misses.contains(key) { return nil }

        guard let summaryURL = Self.summaryURL(for: scientificName),
              let (data, response) = try? await URLSession.shared.data(from: summaryURL),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            misses.insert(key)
            return nil
        }

        let blurb = json["extract"] as? String
        let page = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String

        var imageData: Data?
        if let thumb = json["thumbnail"] as? [String: Any],
           let source = thumb["source"] as? String,
           let imageURL = URL(string: source),
           let (bytes, imageResponse) = try? await URLSession.shared.data(from: imageURL),
           let imageHTTP = imageResponse as? HTTPURLResponse, (200...299).contains(imageHTTP.statusCode) {
            imageData = bytes
        }

        let info = SpeciesInfo(blurb: blurb, imageData: imageData, pageURL: page.flatMap(URL.init(string:)))
        if info.isEmpty {
            misses.insert(key)
            return nil
        }
        cache[key] = info
        return info
    }

    private static func summaryURL(for scientificName: String) -> URL? {
        let title = scientificName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
    }
}

/// Shows a thumbnail + short blurb for a species. Renders nothing intrusive
/// when offline or when no article is found.
struct SpeciesInfoView: View {
    let scientificName: String

    @State private var info: SpeciesInfo?
    @State private var loaded = false

    var body: some View {
        Group {
            if let info {
                HStack(alignment: .top, spacing: 10) {
                    if let data = info.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let blurb = info.blurb {
                        Text(blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if loaded {
                Text("No background info available (offline or no article found).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: scientificName) {
            loaded = false
            info = await SpeciesEnrichmentService.shared.info(forScientificName: scientificName)
            loaded = true
        }
    }
}
