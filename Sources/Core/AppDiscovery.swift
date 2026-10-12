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

    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private var rescanWorkItem: DispatchWorkItem?

    func loadInBackground() {
        Task.detached(priority: .utility) { [weak self] in
            let found = Self.scan()
            guard let self else { return }
            await MainActor.run {
                self.apply(found)
                self.rebuildWatchers()
            }
        }
    }

    /// Installing or removing an app changes the contents of the folder it
    /// lives in — without this, a freshly installed app just never showed
    /// up in the start menu until the bar itself was relaunched (and a
    /// trashed one never left). Same debounced-file-watcher approach
    /// `ThemeStore` already uses for its theme folder, just watching
    /// directory *listings* instead of a single file's contents.
    ///
    /// Watches the standard directories *and* the plain folders directly
    /// inside them (`/Applications/Utilities`, a vendor's own subfolder…):
    /// the scan reaches apps there too, but trashing one of them only
    /// changes its own subfolder, which a watch on `/Applications` alone
    /// never sees. Rebuilt after every scan, so a subfolder created later
    /// gets picked up too.
    private func rebuildWatchers() {
        directoryWatchers.forEach { $0.cancel() }
        directoryWatchers.removeAll()

        var directories = Self.standardDirectories
        for directory in Self.standardDirectories {
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries where entry.pathExtension != "app" {
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    directories.append(entry)
                }
            }
        }
        for directory in directories {
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleRescan() }
            source.setCancelHandler { close(fd) }
            source.resume()
            directoryWatchers.append(source)
        }
    }

    /// Drops any app whose bundle is no longer on disk — a cheap existence
    /// check (no rescan), so it can run every time the start menu opens.
    @MainActor
    func pruneMissingApps() {
        let remaining = apps.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard remaining.count != apps.count else { return }
        apps = remaining
        categories = Array(Set(remaining.map(\.category))).sorted()
    }

    /// Debounced: installing an app (unzip, drag-copy, an installer package)
    /// can touch its directory several times in a row as it writes — this
    /// waits for things to settle instead of rescanning on every single
    /// event.
    private func scheduleRescan() {
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadInBackground()
        }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// The confirmation step every start menu style's own "Déplacer à la
    /// corbeille" context menu item goes through first — same
    /// warning-alert pattern as any other destructive action in this app
    /// (e.g. shutdown's own native confirmation). Shared here instead of
    /// copied into each of the three start menu views.
    func confirmAndUninstall(_ app: InstalledApp) {
        let alert = NSAlert()
        alert.messageText = L("alert.trash_app.title", ["name": app.displayName])
        alert.informativeText = L("alert.trash_app.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("app.trash"))
        alert.addButton(withTitle: L("button.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            uninstall(app)
        }
    }

    /// Moves an app to the Trash (reversible, like Launchpad's own "Delete
    /// App"), used by the start menu's right-click "Déplacer à la corbeille".
    ///
    /// Goes through `NSWorkspace.recycle`, not `FileManager.trashItem` —
    /// this app has no special entitlement of its own, so trashing
    /// anything our own process doesn't already own outright (most
    /// installed apps, in practice) failed with a plain permission error
    /// instead of ever offering to authenticate. `NSWorkspace.recycle`
    /// delegates the actual move to the Finder/Workspace services, the
    /// same path a real Finder drag-to-Trash goes through — including its
    /// own admin-password prompt when the app genuinely needs one, which a
    /// raw `FileManager` call has no way to trigger on our behalf.
    func uninstall(_ app: InstalledApp) {
        NSWorkspace.shared.recycle([app.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let error else {
                    self.apps.removeAll { $0.id == app.id }
                    // The Finder's own "move to trash" sound — a different
                    // fixed AIFF from the Dock's drag-and-drop one (see
                    // `TaskDragItem.trashDroppedFiles`), matching that this
                    // action came from a menu, not a drag.
                    NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif", byReference: true)?.play()
                    return
                }
                let alert = NSAlert()
                alert.messageText = L("alert.uninstall_failed.title", ["name": app.displayName])
                alert.informativeText = L("alert.uninstall_failed.message", ["error": error.localizedDescription])
                alert.alertStyle = .warning
                alert.runModal()
            }
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
        // Something in the Trash is, as far as the user's concerned, gone —
        // Spotlight still indexes it.
        guard !url.path.contains("/.Trash/") else { return nil }

        guard let bundle = Bundle(url: url) else { return nil }

        // `LSUIElement`/`LSBackgroundOnly` used to exclude every app that
        // sets either flag, meant to filter out internal helper/agent
        // bundles — but plenty of real, top-level apps in /Applications
        // set the same flag deliberately because they're *menu-bar-only*
        // by design (Tailscale, Bartender, Rectangle, …), not because
        // they're junk. Those belong in the launcher; a user who installed
        // one wants to find and quit it from somewhere. The actual
        // internal helpers this was trying to keep out are already
        // excluded on their own: nested bundles are skipped just above,
        // and `/System/Library/CoreServices` (where most of them live)
        // isn't scanned at all.
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
