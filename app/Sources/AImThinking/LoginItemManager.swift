import ServiceManagement

enum LoginItemManager {
    static var approvalMessage: String? {
        SMAppService.mainApp.status == .requiresApproval
            ? "Allow aI'm Thinking in System Settings → General → Login Items." : nil
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

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
}
