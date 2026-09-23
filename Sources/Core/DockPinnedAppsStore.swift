import AppKit

/// An app pinned to the real macOS Dock (its `persistent-apps` list), shown
/// in our taskbar as a launcher even when it isn't currently running — this
/// is what keeps the taskbar "synced" with the Dock so nothing pinned there
/// becomes hard to reach once the Dock itself is hidden.
struct PinnedApp: Identifiable {
    var id: String { url.path }
    let url: URL
    let displayName: String
    let bundleIdentifier: String?
    /// The exact plist dictionary this was parsed from, when it came from
    /// an existing Dock entry. Real Dock-authored entries carry a `book`
    /// bookmark (plus other metadata) that a from-scratch entry doesn't —
    /// rewriting the whole list from synthesized entries once stripped
    /// every real pinned app down to bare url+label and broke their Dock
    /// icons ("?" placeholders). Reordering now reuses this untouched
    /// wherever it exists, instead of ever reconstructing an existing pin.
    let rawEntry: [String: Any]?

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

extension PinnedApp: Equatable {
    static func == (lhs: PinnedApp, rhs: PinnedApp) -> Bool { lhs.id == rhs.id }
}

extension PinnedApp: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Reads and writes the real Dock's `persistent-apps` list directly, so
/// pinning/unpinning from our taskbar or start menu stays in sync with the
/// (now hidden) native Dock — matching the app's whole premise: nothing
/// pinned there should become hard to reach.
enum DockPinnedAppsStore {
    private static let dockDomain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString

    /// Reads `~/Library/Preferences/com.apple.dock.plist`'s `persistent-apps`
    /// directly (same mechanism `DockController` already uses to read/write
    /// Dock preferences), so this always reflects whatever is actually
    /// pinned to the Dock right now — including changes made after our app
    /// started, by us or by the user through any other means.
    static func read() -> [PinnedApp] {
        rawEntries().compactMap(parse)
    }

    static func isPinned(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return read().contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Appends `url` to the Dock's pinned apps, if it isn't already there.
    static func pin(url: URL, displayName: String) {
        var entries = rawEntries()
        let alreadyPinned = entries.contains { entry in
            guard let tileData = entry["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String else { return false }
            return urlString == url.absoluteString
        }
        guard !alreadyPinned else { return }

        entries.append(makeEntry(url: url, displayName: displayName))
        write(entries)
    }

    /// Replaces the whole pinned-apps list with `order`, in that exact
    /// order — used for drag-to-reorder in our taskbar/start menu. Reuses
    /// each app's original entry dict untouched whenever it has one (i.e.
    /// it was already pinned); only synthesizes a fresh minimal entry for
    /// an app that's being pinned for the first time by this reorder.
    static func reorder(to order: [PinnedApp]) {
        write(order.map { $0.rawEntry ?? makeEntry(url: $0.url, displayName: $0.displayName) })
    }

    /// A freshly-synthesized entry, formatted to match what the real Dock
    /// itself writes (`_CFURLStringType: 15`, plus a proper bookmark) —
    /// verified against real Dock-authored entries, since a mismatch here
    /// is exactly what caused the "?" icon bug this replaced.
    private static func makeEntry(url: URL, displayName: String) -> [String: Any] {
        var fileData: [String: Any] = [
            "_CFURLString": url.absoluteString,
            "_CFURLStringType": 15
        ]
        if let bookmark = try? url.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil) {
            fileData["book"] = bookmark
        }
        return [
            "tile-type": "file-tile",
            "tile-data": [
                "file-label": displayName,
                "file-data": fileData
            ]
        ]
    }

    /// Removes any pinned entry pointing at `url` (or matching
    /// `bundleIdentifier`, for entries whose stored path has drifted).
    static func unpin(url: URL, bundleIdentifier: String?) {
        var entries = rawEntries()
        entries.removeAll { entry in
            guard
                let tileData = entry["tile-data"] as? [String: Any],
                let fileData = tileData["file-data"] as? [String: Any],
                let urlString = fileData["_CFURLString"] as? String,
                let entryURL = URL(string: urlString)
            else {
                return false
            }
            if entryURL.standardizedFileURL == url.standardizedFileURL { return true }
            if let bundleIdentifier, Bundle(url: entryURL)?.bundleIdentifier == bundleIdentifier { return true }
            return false
        }
        write(entries)
    }

    // MARK: - Plumbing

    private static func rawEntries() -> [[String: Any]] {
        CFPreferencesCopyValue(key, dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [[String: Any]] ?? []
    }

    private static func write(_ entries: [[String: Any]]) {
        CFPreferencesSetValue(key, entries as CFPropertyList, dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }

    private static func parse(_ entry: [String: Any]) -> PinnedApp? {
        guard
            let tileData = entry["tile-data"] as? [String: Any],
            let fileData = tileData["file-data"] as? [String: Any],
            let urlString = fileData["_CFURLString"] as? String,
            let url = URL(string: urlString)
        else {
            return nil
        }
        let label = (tileData["file-label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        return PinnedApp(url: url, displayName: label, bundleIdentifier: bundleIdentifier, rawEntry: entry)
    }
}
