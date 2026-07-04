import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var viewModel: BirdDetectionViewModel?

    // Notification permission is requested on the first detection that wants to
    // notify (see BirdDetectionViewModel.sendNotification) — asking at launch,
    // before the app has shown any value, invites a reflexive "Don't Allow".
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            viewModel?.openMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.shutdown()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
