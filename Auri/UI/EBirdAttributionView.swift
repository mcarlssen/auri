import SwiftUI

struct EBirdAttributionView: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Regional data provided by")
            Link("eBird.org", destination: URL(string: "https://ebird.org")!)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
