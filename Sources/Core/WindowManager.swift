import AppKit
import ApplicationServices
import Observation

/// Not in any public header, but a long-standing, widely-relied-upon symbol
/// (used by e.g. yabai, Hammerspoon, Amethyst) for turning an AXUIElement
/// window into the same stable `CGWindowID` the window server itself uses.
/// AX's own `kAXWindowsAttribute` enumeration order/title aren't stable
/// identifiers (order can change across polls, titles change as content
/// changes) — this is what makes "which window was this" reliable across
/// refreshes, which minimize/restore and window grouping both depend on.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A single on-screen window, backed by its Accessibility element.
struct AppWindow: Identifiable {
    let id: String
    let axElement: AXUIElement
    let pid: pid_t
    let bundleIdentifier: String?
    var title: String
    var appName: String
    var appIcon: NSImage?
    var isMinimized: Bool
}

/// One slot in the taskbar's unified task list: a single running window, a
/// group of windows belonging to the same app (hover shows a clickable
/// list), or a Dock-pinned app that isn't running yet (click launches it).
/// Pinned launchers are what keeps the taskbar's icons "synced" with the
/// real Dock — mirrors how Plasma's own Task Manager mixes pinned launchers
/// and running tasks in one row.
enum TaskbarEntry: Identifiable {
    case window(AppWindow)
    case group(bundleIdentifier: String, appName: String, appIcon: NSImage?, windows: [AppWindow])
    case launcher(PinnedApp)

    var id: String {
        switch self {
        case .window(let window): return "w-\(window.id)"
        case .group(let bundleIdentifier, _, _, _): return "g-\(bundleIdentifier)"
        case .launcher(let app): return "l-\(app.id)"
        }
    }
}

/// Enumerates running applications' windows via the Accessibility API and
/// exposes actions to raise, minimize, or minimize-all of them. Also reads
/// the real Dock's pinned apps so the taskbar can show launchers for
/// anything pinned there, running or not.
///
/// Requires Accessibility permission (see `PermissionsManager`); every AX
/// call here is a no-op (returns an error we swallow) until that's granted.
@Observable
final class WindowManager {
    private(set) var windows: [AppWindow] = []
    private(set) var pinnedApps: [PinnedApp] = []
    /// Owned here (instead of view-local `@State`) so button views can stay
    /// plain, macro-free SwiftUI views. See ShortcutsManager for why.
    var hoveredWindowID: String?
    var hoveredGroupID: String?
    private var hoverClearWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?

    /// System UI surfaces (Spotlight's search overlay, etc.) sometimes show
    /// up as a regular, windowed process, but aren't "apps" someone would
    /// want in a taskbar — unless they went out of their way to pin them.
    private static let hiddenUnlessPinnedBundleIDs: Set<String> = [
        "com.apple.Spotlight"
    ]

    /// Pinned launchers first (Dock order), each replaced by its window(s)
    /// once running (grouped under one icon when there's more than one);
    /// any other running window/group follows.
    var entries: [TaskbarEntry] {
        var result: [TaskbarEntry] = []
        var consumedWindowIDs = Set<String>()

        for pinned in pinnedApps {
            let matches = windows.filter { $0.bundleIdentifier != nil && $0.bundleIdentifier == pinned.bundleIdentifier }
            if matches.isEmpty {
                result.append(.launcher(pinned))
            } else {
                result.append(contentsOf: Self.groupedEntries(for: matches))
                consumedWindowIDs.formUnion(matches.map(\.id))
            }
        }

        let remaining = windows.filter { !consumedWindowIDs.contains($0.id) }
        result.append(contentsOf: Self.groupedEntries(for: remaining))
        return result
    }

    /// Splits a set of windows into entries, grouping same-app windows
    /// (2+) under one `.group` entry, keeping a lone window as `.window`.
    private static func groupedEntries(for windows: [AppWindow]) -> [TaskbarEntry] {
        var order: [String] = []
        var byKey: [String: [AppWindow]] = [:]
        for window in windows {
            let key = window.bundleIdentifier ?? "pid-\(window.pid)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(window)
        }
        return order.map { key in
            let group = byKey[key]!
            if group.count == 1 {
                return .window(group[0])
            }
            return .group(bundleIdentifier: key, appName: group[0].appName, appIcon: group[0].appIcon, windows: group)
        }
    }

    func startAutoRefresh(interval: TimeInterval = 2.0) {
        refresh()
        refreshPinnedApps()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.refreshPinnedApps()
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshPinnedApps() {
        let updated = DockPinnedAppsStore.read()
        if updated.map(\.id) != pinnedApps.map(\.id) {
            pinnedApps = updated
        }
    }

    func isPinned(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return pinnedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Pins/unpins from the start menu or the taskbar itself — writes
    /// straight to the real Dock's `persistent-apps`, so both stay in sync.
    func pin(url: URL, displayName: String) {
        DockPinnedAppsStore.pin(url: url, displayName: displayName)
        refreshPinnedApps()
    }

    func unpin(url: URL, bundleIdentifier: String?) {
        DockPinnedAppsStore.unpin(url: url, bundleIdentifier: bundleIdentifier)
        refreshPinnedApps()
    }

    /// Convenience for task buttons, which only know a running window's
    /// pid — looks up its app bundle to pin/unpin by.
    func togglePin(pid: pid_t, bundleIdentifier: String?, displayName: String) {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
        if isPinned(bundleIdentifier: bundleIdentifier) {
            unpin(url: url, bundleIdentifier: bundleIdentifier)
        } else {
            pin(url: url, displayName: displayName)
        }
    }

    /// Drag-and-drop reordering of taskbar icons, synced with the real
    /// Dock: moves `draggedBundleIdentifier` to sit at
    /// `droppedOnBundleIdentifier`'s position among everything currently
    /// shown in the taskbar. Anything touched by the drag that wasn't
    /// already pinned becomes pinned — only pinned apps have a persistent
    /// position, so that's the only way a manual reorder can "stick".
    func reorder(draggedBundleIdentifier: String, droppedOnBundleIdentifier: String) {
        guard draggedBundleIdentifier != droppedOnBundleIdentifier else { return }

        var order = currentEntryBundleIdentifiers()
        guard let fromIndex = order.firstIndex(of: draggedBundleIdentifier) else { return }
        order.remove(at: fromIndex)
        guard let toIndex = order.firstIndex(of: droppedOnBundleIdentifier) else { return }
        order.insert(draggedBundleIdentifier, at: toIndex)

        applyOrder(order)
    }

    /// Every taskbar entry's bundle identifier, in the order they're
    /// currently shown (pinned launchers first in Dock order, then any
    /// other running app) — the ordering a drag operates on.
    private func currentEntryBundleIdentifiers() -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for entry in entries {
            let bundleIdentifier: String?
            switch entry {
            case .window(let window): bundleIdentifier = window.bundleIdentifier
            case .group(let bundleID, _, _, _): bundleIdentifier = bundleID
            case .launcher(let app): bundleIdentifier = app.bundleIdentifier
            }
            if let bundleIdentifier, !seen.contains(bundleIdentifier) {
                seen.insert(bundleIdentifier)
                order.append(bundleIdentifier)
            }
        }
        return order
    }

    /// Rewrites the Dock's pinned-apps list to exactly this order,
    /// resolving each identifier's app bundle from whichever is running or
    /// already pinned right now.
    private func applyOrder(_ bundleIdentifiers: [String]) {
        var newOrder: [PinnedApp] = []
        for bundleIdentifier in bundleIdentifiers {
            if let existing = pinnedApps.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                newOrder.append(existing)
            } else if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
                      let url = running.bundleURL {
                let name = running.localizedName ?? url.deletingPathExtension().lastPathComponent
                newOrder.append(PinnedApp(url: url, displayName: name, bundleIdentifier: bundleIdentifier, rawEntry: nil))
            }
        }
        DockPinnedAppsStore.reorder(to: newOrder)
        refreshPinnedApps()
    }

    /// Hover state for a grouped icon's popover, with a short grace period
    /// before clearing — without it, moving the mouse from the icon to the
    /// popover's own content (a different view, briefly un-hovered in
    /// between) would dismiss the popover before the user could click it.
    func setGroupHovered(_ id: String, hovering: Bool) {
        if hovering {
            hoverClearWorkItem?.cancel()
            hoveredGroupID = id
        } else {
            let work = DispatchWorkItem { [weak self] in
                if self?.hoveredGroupID == id { self?.hoveredGroupID = nil }
            }
            hoverClearWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private var externalDragHoverWorkItem: DispatchWorkItem?

    /// Dock/taskbar "spring loading": hovering a drag of files from another
    /// app over a taskbar icon for half a second brings that app forward,
    /// so the files can be dropped onto its actual window once it's
    /// visible — same idea as the real Dock, just without also trying to
    /// redeliver the drop ourselves (our panel stays above everything, so
    /// the user drags on to the now-raised window to finish the drop).
    func handleExternalDragHover(isTargeted: Bool, action: @escaping () -> Void) {
        externalDragHoverWorkItem?.cancel()
        guard isTargeted else { return }
        let work = DispatchWorkItem(block: action)
        externalDragHoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            windows = []
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let runningPIDs = Set(runningApps.map(\.processIdentifier))
        let pinnedBundleIDs = Set(pinnedApps.compactMap(\.bundleIdentifier))

        var collected: [AppWindow] = []
        var seenIDs = Set<String>()

        for app in runningApps {
            if let bundleID = app.bundleIdentifier,
               Self.hiddenUnlessPinnedBundleIDs.contains(bundleID),
               !pinnedBundleIDs.contains(bundleID) {
                continue
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let axWindows = Self.copyArrayAttribute(appElement, kAXWindowsAttribute) ?? []

            for axWindow in axWindows {
                let title = Self.copyStringAttribute(axWindow, kAXTitleAttribute) ?? app.localizedName ?? L("window.untitled")
                guard Self.isRealWindow(axWindow, title: title, bundleIdentifier: app.bundleIdentifier) else { continue }

                let id = Self.stableID(for: axWindow, pid: app.processIdentifier, title: title)
                guard !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)

                let minimized = Self.copyBoolAttribute(axWindow, kAXMinimizedAttribute) ?? false
                collected.append(AppWindow(
                    id: id,
                    axElement: axWindow,
                    pid: app.processIdentifier,
                    bundleIdentifier: app.bundleIdentifier,
                    title: title,
                    appName: app.localizedName ?? "Application",
                    appIcon: app.icon,
                    isMinimized: minimized
                ))
            }
        }

        // Some apps stop listing a window in `kAXWindowsAttribute` once it's
        // the only (now fully minimized) window — instead of losing it
        // entirely (and with it, any way to bring it back), re-verify
        // anything we tracked last pass that didn't reappear this time by
        // querying its cached AXUIElement directly.
        for previous in windows {
            guard runningPIDs.contains(previous.pid) else { continue } // app quit: drop it
            guard !seenIDs.contains(previous.id) else { continue } // already re-collected fresh

            var titleValue: CFTypeRef?
            let stillValid = AXUIElementCopyAttributeValue(previous.axElement, kAXTitleAttribute as CFString, &titleValue) == .success
            guard stillValid else { continue } // window truly closed: drop it

            var reAdded = previous
            reAdded.isMinimized = Self.copyBoolAttribute(previous.axElement, kAXMinimizedAttribute) ?? true
            collected.append(reAdded)
            seenIDs.insert(previous.id)
        }

        windows = collected
    }

    func raise(_ window: AppWindow) {
        AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementSetAttributeValue(window.axElement, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate()
        }
        refresh()
    }

    func toggleMinimize(_ window: AppWindow) {
        if window.isMinimized {
            raise(window)
        } else {
            AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            refresh()
        }
    }

    /// Left-click behavior on a task button, Windows-taskbar style: bring a
    /// not-frontmost window forward, but minimize one that's already
    /// frontmost — a plain toggle (used by the right-click menu instead)
    /// would minimize a window the user just switched to from another app.
    func activateOrMinimize(_ window: AppWindow) {
        if window.isMinimized {
            raise(window)
            return
        }
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        if isFrontmost {
            AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            refresh()
        } else {
            raise(window)
        }
    }

    func launch(_ pinned: PinnedApp) {
        // Finder is always running (it owns the desktop), so treating it
        // like any other "closed" app and just activating it wouldn't open
        // a window — open one explicitly instead.
        if pinned.bundleIdentifier == "com.apple.finder" {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        NSWorkspace.shared.openApplication(at: pinned.url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Closes a window via its AX close button (the same element the red
    /// traffic-light button performs), rather than quitting the app.
    func close(_ window: AppWindow) {
        var closeButton: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.axElement, kAXCloseButtonAttribute as CFString, &closeButton)
        if result == .success, let closeButton {
            AXUIElementPerformAction((closeButton as! AXUIElement), kAXPressAction as CFString)
        }
        refresh()
    }

    /// The set of window ids minimized by the last `minimizeAll()` call, so
    /// pressing the button again restores exactly those windows instead of
    /// minimizing (already-minimized) everything again.
    private var lastShowDesktopWindowIDs: Set<String> = []

    /// "Minimize all", toggled: press once to minimize everything visible,
    /// press again to bring back exactly what that press hid.
    func minimizeAll() {
        if !lastShowDesktopWindowIDs.isEmpty {
            for window in windows where lastShowDesktopWindowIDs.contains(window.id) {
                AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
            lastShowDesktopWindowIDs = []
        } else {
            let toMinimize = windows.filter { !$0.isMinimized }
            for window in toMinimize {
                AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            }
            lastShowDesktopWindowIDs = Set(toMinimize.map(\.id))
        }
        refresh()
    }

    /// Used by the ⌘⌥1…9 shortcuts: activates the Nth item exactly as shown
    /// in the taskbar (pinned launchers and window groups included).
    func activateEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        switch entries[index] {
        case .window(let window): raise(window)
        case .group(_, _, _, let windows): windows.first.map(raise)
        case .launcher(let app): launch(app)
        }
    }

    // MARK: - Window identity

    /// A `CGWindowID`-based id when the private symbol resolves and
    /// succeeds (stable across refreshes and title changes); falls back to
    /// pid+title, which is what this app used before and is only unstable
    /// if a window's title changes while the app has multiple windows.
    private static func stableID(for axWindow: AXUIElement, pid: pid_t, title: String) -> String {
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 {
            return "cg-\(windowID)"
        }
        return "\(pid)-\(title)"
    }

    // MARK: - AX attribute helpers

    private static func isRealWindow(_ element: AXUIElement, title: String, bundleIdentifier: String?) -> Bool {
        // Filter out AX-visible but non-window artifacts (menus, popovers) that
        // sometimes surface an empty/system title.
        guard !title.isEmpty else { return false }

        // Finder is always running and always reports an AX window for the
        // desktop itself, even with zero actual Finder windows open — which
        // would otherwise make Finder look permanently "open" in the
        // taskbar. Only its real Finder-window subrole counts.
        if bundleIdentifier == "com.apple.finder" {
            let subrole = copyStringAttribute(element, kAXSubroleAttribute) ?? ""
            return subrole == (kAXStandardWindowSubrole as String)
        }
        return true
    }

    private static func copyArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}
