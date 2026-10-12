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

    /// Every start menu style shows the same "most recently launched
    /// first" ordering now, not just `Windows7StartMenuView` — shared here
    /// instead of copied three times. Apps never launched through this app
    /// keep `bundleIdentifiers`' own relative order (typically
    /// `AppDiscovery`'s alphabetical one), after all the ones that do have
    /// a recorded timestamp.
    static func sortedByRecency<App>(_ apps: [App], bundleIdentifier: (App) -> String?) -> [App] {
        // Read once up front, not per comparison: `lastLaunchTimestamp`
        // re-parses the whole stored dictionary out of `UserDefaults` on
        // every call, and a sort calls it twice per comparison — thousands
        // of reads for a few hundred apps, on every re-render of a menu
        // that sorts in its `body`, which is what made scrolling stutter.
        let timestamps = allTimestamps()
        return apps.enumerated()
            .map { (offset: $0.offset, element: $0.element, timestamp: bundleIdentifier($0.element).flatMap { timestamps[$0] }) }
            .sorted { lhs, rhs in
                switch (lhs.timestamp, rhs.timestamp) {
                case (let l?, let r?): return l > r
                case (nil, nil): return lhs.offset < rhs.offset
                case (.some, nil): return true
                case (nil, .some): return false
                }
            }
            .map(\.element)
    }
}
