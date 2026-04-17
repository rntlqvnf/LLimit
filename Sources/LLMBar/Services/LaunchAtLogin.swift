import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` so SwiftUI views can read
/// and toggle the "open at login" state without importing ServiceManagement.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            FileHandle.standardError.write(
                Data("[launchAtLogin] toggle failed: \(error)\n".utf8)
            )
        }
    }
}
