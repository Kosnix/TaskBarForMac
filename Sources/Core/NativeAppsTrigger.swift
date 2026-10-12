import AppKit

/// Opens (or closes — it's a toggle) macOS's own "Apps" menu, used when the
/// start menu style is "Apps (macOS)". `Apps.app` is only a tiny stub that
/// asks the system to toggle the real UI and exits right away, so launching
/// it is the whole trick; it must not activate, or the menu loses focus the
/// moment it appears.
enum NativeAppsTrigger {
    private static let url = URL(fileURLWithPath: "/System/Applications/Apps.app")

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func toggle() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
