import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: BirdDetectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            RuntimeControlsView(viewModel: viewModel)
            Button("Open Auri") {
                viewModel.openMainWindow()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 360, height: 180)
        .onAppear {
            Task { await viewModel.bootstrapIfNeeded() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Auri")
                .font(.title2.bold())
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

}
