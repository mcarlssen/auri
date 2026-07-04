import SwiftUI

@main
struct AuriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = BirdDetectionViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .background(WindowOpener(viewModel: viewModel))
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        } label: {
            MenuBarIcon(audioHandler: viewModel.audioHandler)
        }
        .menuBarExtraStyle(.window)

        Window("Auri", id: "main") {
            MainWindowView(viewModel: viewModel)
        }
        .defaultSize(width: 900, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Menu bar icon that reflects listening state: filled bird while
/// listening, outlined bird while paused.
private struct MenuBarIcon: View {
    @ObservedObject var audioHandler: AudioHandler

    var body: some View {
        Image(systemName: audioHandler.isRunning ? "bird.fill" : "bird")
            .accessibilityLabel(audioHandler.isRunning ? "Auri, listening" : "Auri, paused")
    }
}
