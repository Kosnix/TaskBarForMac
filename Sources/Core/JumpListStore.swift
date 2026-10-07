import AppKit
import Observation

/// The extras a taskbar icon's right-click menu offers, Windows 7 jump-list
/// style: "New Window" and the files the app was last used with.
///
/// A SwiftUI `.contextMenu` is built before it's shown and can't wait for
/// anything, so the data is fetched when the pointer first reaches the icon
/// (`prefetch`) — a right-click needs a hover first, and by then the answer
/// is normally in.
///
/// "Recent files" are the user's most recently used files of the kinds the
/// app declares it opens (its `CFBundleDocumentTypes`) — the app's own
/// recent-documents list lives in a TCC-protected folder this app can't read.
@MainActor
@Observable
final class JumpListStore {
    static let shared = JumpListStore()

    private(set) var canOpenNewWindow: [String: Bool] = [:]
    @ObservationIgnored private var searches: [String: FileSearch] = [:]
    @ObservationIgnored private var lastPrefetch: [String: Date] = [:]
    /// Too generic to say anything about what an app is for.
    private static let genericTypes: Set<String> = [
        "public.data", "public.item", "public.content", "public.composite-content",
        "public.folder", "public.directory", "public.executable", "public.archive",
    ]

    /// Recent files for this app, most recent first (empty until fetched).
    /// Reading registers with the observation system, so the menu rebuilds
    /// when the query finishes.
    func recentFiles(for bundleIdentifier: String) -> [URL] {
        searches[bundleIdentifier]?.results.map(\.url) ?? []
    }

    func prefetch(bundleIdentifier: String?, appURL: URL?, pid: pid_t?) {
        guard let bundleIdentifier else { return }
        // At most every 20 s per app — hovering back and forth shouldn't
        // keep re-running Spotlight queries.
        if let last = lastPrefetch[bundleIdentifier], Date().timeIntervalSince(last) < 20 { return }
        lastPrefetch[bundleIdentifier] = Date()

        if searches[bundleIdentifier] == nil, let appURL, let types = Self.documentTypes(of: appURL), !types.isEmpty {
            let search = FileSearch(limit: 5)
            searches[bundleIdentifier] = search
            search.loadRecents(contentTypes: types)
        } else if let search = searches[bundleIdentifier], let appURL, let types = Self.documentTypes(of: appURL) {
            search.loadRecents(contentTypes: types)
        }
        if let pid {
            canOpenNewWindow[bundleIdentifier] = Self.newWindowMenuItem(pid: pid) != nil
        }
    }

    func openNewWindow(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
        guard let item = Self.newWindowMenuItem(pid: pid) else { return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    func open(_ file: URL, withAppAt appURL: URL?) {
        if let appURL {
            NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    // MARK: - App inspection

    private static func documentTypes(of appURL: URL) -> [String]? {
        guard let info = Bundle(url: appURL)?.infoDictionary,
              let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return nil }
        let types = documentTypes
            .compactMap { $0["LSItemContentTypes"] as? [String] }
            .flatMap { $0 }
            .filter { !genericTypes.contains($0) }
        return Array(Set(types)).sorted().prefix(30).map { $0 }
    }

    private static let newWindowTitles = ["new window", "nouvelle fenêtre", "nueva ventana", "новое окно", "new finder window"]

    /// The enabled "New Window" item in the app's menu bar, if it has one —
    /// matched on its title, in the app's four supported languages, skipping
    /// private-browsing variants.
    private static func newWindowMenuItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = element(app, kAXMenuBarAttribute),
              let barItems = elements(menuBar, kAXChildrenAttribute) else { return nil }
        // First entry is the Apple menu.
        for barItem in barItems.dropFirst() {
            guard let menu = elements(barItem, kAXChildrenAttribute)?.first,
                  let items = elements(menu, kAXChildrenAttribute) else { continue }
            for item in items {
                guard let title = string(item, kAXTitleAttribute)?.lowercased(), !title.isEmpty,
                      !title.contains("priv"),
                      newWindowTitles.contains(where: { title.hasPrefix($0) }),
                      bool(item, kAXEnabledAttribute) != false else { continue }
                return item
            }
        }
        return nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
