import Foundation

/// Remembers when each app was last launched *through this taskbar*
/// (start menu click, pinned-launcher click, …), so a menu can offer a
/// "most recently used first" ordering — e.g. `Windows7StartMenuView`'s
/// app list — instead of a fixed alphabetical one. Persisted, so the order
/// survives a relaunch instead of resetting every time the bar restarts.
enum LaunchHistoryStore {
    private static let key = "TB.launchHistory"

    static func recordLaunch(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        var history = allTimestamps()
        history[bundleIdentifier] = Date().timeIntervalSinceReferenceDate
        UserDefaults.standard.set(history, forKey: key)
    }

    /// Higher means more recently launched; apps never launched through
    /// this app sort after all of these (see call sites).
    static func lastLaunchTimestamp(bundleIdentifier: String?) -> Double? {
        guard let bundleIdentifier else { return nil }
        return allTimestamps()[bundleIdentifier]
    }

    private static func allTimestamps() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
}
