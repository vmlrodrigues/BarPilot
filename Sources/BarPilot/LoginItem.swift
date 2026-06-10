import AppKit
import ServiceManagement

// ---------------------------------------------------------------------------
// LoginItem — "Start at Login", backed by SMAppService (macOS 13+).
// Registers the app itself as a login item; no helper bundle or LaunchAgent
// plumbing required.
// ---------------------------------------------------------------------------

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("BarPilot: Start at Login toggle failed: \(error.localizedDescription)")
            // If macOS wants the user to approve it, take them to the setting.
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
