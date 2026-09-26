import ServiceManagement

/// "Launch at login", via the native `ServiceManagement` API rather than a
/// hand-rolled login-items script — the real, current state always comes
/// straight from macOS (`SMAppService.mainApp.status`) instead of being
/// separately remembered in this app's own preferences, so it can never
/// drift out of sync with what the system actually has registered.
enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[LaunchAtLoginManager] failed to \(enabled ? "register" : "unregister"): \(error)")
        }
    }
}
