import Foundation
import ServiceManagement

enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func sync(with preferenceEnabled: Bool) {
        do {
            if preferenceEnabled && !isEnabled {
                try setEnabled(true)
            } else if !preferenceEnabled && isEnabled {
                try setEnabled(false)
            }
        } catch {
            // Preference remains stored; user can retry from Settings.
        }
    }
}
