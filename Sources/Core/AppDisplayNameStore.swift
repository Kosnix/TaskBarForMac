import Foundation

/// Custom per-app display names, set via "Rename" from any start menu's
/// context menu (see `WindowManager.promptRename`) — mirrors
/// `IconOverrideStore`'s own shape (keyed by bundle identifier, applies
/// everywhere that app's name is drawn) but for a plain string instead of
/// an image, so it's just a small `UserDefaults`-backed dictionary rather
/// than files on disk. Purely cosmetic and local to this app: it never
/// touches the app's real name on disk, in Spotlight, or anywhere else
/// outside TaskBarForMac's own UI.
enum AppDisplayNameStore {
    private static let key = "TB.appDisplayNames"

    private static var overrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func customName(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        return overrides[bundleIdentifier]
    }

    static func setCustomName(_ name: String, for bundleIdentifier: String) {
        var current = overrides
        current[bundleIdentifier] = name
        overrides = current
    }

    static func removeCustomName(for bundleIdentifier: String) {
        var current = overrides
        current.removeValue(forKey: bundleIdentifier)
        overrides = current
    }
}
