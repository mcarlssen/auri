import SwiftUI

@main
struct AuriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = BirdDetectionViewModel()

    var body: some Scene {
        MenuBarExtra("Auri", systemImage: "bird.fill") {
            MenuBarView(viewModel: viewModel)
                .background(WindowOpener(viewModel: viewModel))
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .menuBarExtraStyle(.window)

        Window("Auri", id: "main") {
            MainWindowView(viewModel: viewModel)
        }
        .defaultSize(width: 900, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}
