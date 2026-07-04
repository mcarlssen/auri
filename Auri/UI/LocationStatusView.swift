import CoreLocation
import SwiftUI

struct LocationStatusView: View {
    let isEnabled: Bool
    let location: CLLocation?
    let authorizationStatus: CLAuthorizationStatus
    let regionalLabel: String?
    var hasEBirdKey: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Known location")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(statusText)
                .font(.callout.monospacedDigit())

            if isEnabled, !hasEBirdKey {
                Text("Regional filtering is inactive — add a free eBird API key below to enable it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let regionalLabel {
                Text("eBird region: \(regionalLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let location {
                Text(
                    "±\(Int(location.horizontalAccuracy.rounded())) m accuracy · " +
                    "updated \(location.timestamp.formatted(date: .omitted, time: .shortened))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard isEnabled else {
            return "Location filtering is off."
        }

        switch authorizationStatus {
        case .denied, .restricted:
            return "Location access denied. Enable it in System Settings → Privacy & Security → Location Services."
        case .notDetermined:
            return "Waiting for location permission…"
        default:
            break
        }

        guard let location else {
            return "Acquiring location…"
        }

        let coordinate = location.coordinate
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
