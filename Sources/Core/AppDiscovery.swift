import AppKit
import Observation

struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleIdentifier ?? url.path }
    let url: URL
    let bundleIdentifier: String?
    let displayName: String
    let category: String
    /// Resolved once during the background scan (`makeApp`) instead of on
    /// every SwiftUI render — fetching icons from disk for dozens of cells
    /// the instant the start menu's grid first appears was exactly the kind
    /// of main-thread IO that makes an "open" feel janky instead of instant.
    let icon: NSImage

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Scans the filesystem (and Spotlight, for non-standard install locations)
/// for installed .app bundles, to populate the start menu.
@Observable
final class AppDiscovery {
    private(set) var apps: [InstalledApp] = []
    private(set) var categories: [String] = []

    private static let standardDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]

    /// Finder lives in `/System/Library/CoreServices`, which the scan
    /// otherwise deliberately skips (that's where the internal helper/agent
    /// clutter lives — see `makeApp`'s filtering) — Finder itself is the one
    /// CoreServices app people actually expect in a launcher.
    private static let explicitlyIncludedApps: [URL] = [
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    ]

    func loadInBackground() {
        Task.detached(priority: .utility) { [weak self] in
            let found = Self.scan()
            guard let self else { return }
            await MainActor.run {
                self.apply(found)
            }
        }
    }

    /// Moves an app to the Trash (reversible, like Launchpad's own "Delete
    /// App"), used by the start menu's right-click "Déplacer à la corbeille".
    /// Fails gracefully for SIP-protected system apps.
    func uninstall(_ app: InstalledApp) {
        do {
            try FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
            apps.removeAll { $0.id == app.id }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("alert.uninstall_failed.title", ["name": app.displayName])
            alert.informativeText = L("alert.uninstall_failed.message", ["error": error.localizedDescription])
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @MainActor
    private func apply(_ found: [InstalledApp]) {
        apps = found.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        categories = Array(Set(found.map(\.category))).sorted()
    }

    private static func scan() -> [InstalledApp] {
        var seenPaths = Set<String>()
        var results: [InstalledApp] = []

        for directory in standardDirectories {
            appendBundles(in: directory, into: &results, seen: &seenPaths)
        }
        for url in explicitlyIncludedApps where !seenPaths.contains(url.path) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let app = makeApp(from: url) {
                results.append(app)
                seenPaths.insert(url.path)
            }
        }
        for path in spotlightApplicationPaths() {
            let url = URL(fileURLWithPath: path)
            guard !seenPaths.contains(url.path) else { continue }
            if let app = makeApp(from: url) {
                results.append(app)
                seenPaths.insert(url.path)
            }
        }
        return results
    }

    private static func appendBundles(in directory: URL, into results: inout [InstalledApp], seen: inout Set<String>, depth: Int = 0) {
        guard depth <= 2 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for entry in entries {
            if entry.pathExtension == "app" {
                guard !seen.contains(entry.path) else { continue }
                if let app = makeApp(from: entry) {
                    results.append(app)
                    seen.insert(entry.path)
                }
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                appendBundles(in: entry, into: &results, seen: &seen, depth: depth + 1)
            }
        }
    }

    private static func spotlightApplicationPaths() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // Scoped to user-installable locations only: /System/Applications is
        // already covered by the direct directory walk above, and a
        // system-wide search also surfaces internal helper/agent bundles
        // under /System/Library/CoreServices that don't belong in a launcher.
        process.arguments = [
            "-onlyin", "/Applications",
            "-onlyin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
            "kMDItemContentType == 'com.apple.application-bundle'"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").map(String.init)
    }

    private static func makeApp(from url: URL) -> InstalledApp? {
        // Skip bundles nested inside another app (helpers, XPC services,
        // login items) — only top-level, user-launchable apps belong here.
        let parentPath = url.deletingLastPathComponent().path
        guard !parentPath.contains(".app/") else { return nil }

        guard let bundle = Bundle(url: url) else { return nil }

        // Background agents / UI-less helpers (LSUIElement/LSBackgroundOnly)
        // are registered as real .app bundles with LaunchServices but were
        // never meant to be launched from an app menu.
        guard !isTruthyFlag(bundle, "LSUIElement"), !isTruthyFlag(bundle, "LSBackgroundOnly") else { return nil }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let rawCategory = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        let category = Self.humanCategory(from: rawCategory)

        return InstalledApp(
            url: url,
            bundleIdentifier: bundle.bundleIdentifier,
            displayName: displayName,
            category: category,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
    }

    /// Info.plist booleans are sometimes stored as string/number rather than
    /// an actual boolean plist value; this reads any of those forms.
    private static func isTruthyFlag(_ bundle: Bundle, _ key: String) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) else { return false }
        if let boolValue = value as? Bool { return boolValue }
        if let numberValue = value as? NSNumber { return numberValue.boolValue }
        if let stringValue = value as? String { return (stringValue as NSString).boolValue }
        return false
    }

    /// Maps `public.app-category.*` identifiers to a small, stable set of
    /// internal category keys, grouped the way Kickoff's category list
    /// reads. These keys are used as-is for filtering, sorting and looking
    /// up a theme's `categories.json` icon — never shown directly; see
    /// `Localization.categoryDisplayName(for:)` for the label the start
    /// menu actually displays.
    private static func humanCategory(from raw: String?) -> String {
        guard let raw, let last = raw.split(separator: ".").last else { return "other" }
        let key = String(last)
        let known: Set<String> = [
            "utilities", "developer-tools", "productivity", "graphics-design", "photography",
            "video", "music", "games", "social-networking", "education", "business", "finance",
            "lifestyle", "entertainment", "reference", "news", "sports", "travel", "weather",
            "healthcare-fitness", "medical", "navigation", "system"
        ]
        return known.contains(key) ? key : "other"
    }
}
