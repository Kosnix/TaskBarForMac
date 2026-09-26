import AppKit
import ApplicationServices
import Observation
import SwiftUI

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
    /// Each grouped task button's own frame, in `TaskbarView`'s shared
    /// `"taskbarRoot"` coordinate space — kept live so the hover window-list
    /// popup (rendered at `TaskbarView`'s top level instead of as a
    /// SwiftUI `.popover`, which rendered stretched across the whole bar
    /// instead of anchored to its own button inside this app's
    /// non-activating, unusually-leveled panel) knows where to position
    /// itself for whichever group is currently hovered.
    var groupButtonFrames: [String: CGRect] = [:]
    /// Every taskbar icon's own frame (not just groups — see `groupButtonFrames`
    /// just above, kept separate since it serves a different, older
    /// feature), same shared `"taskbarRoot"` coordinate space. Read by
    /// `PressAndHoldView` (`IconPressGesture.swift`) to figure out which
    /// icon a live reorder-drag is currently over, by simple geometric
    /// containment — reordering no longer goes through SwiftUI's
    /// `.draggable`/`.onDrop` at all, since that system and this app's own
    /// raw-AppKit tap/long-press detector turned out to fight over the same
    /// mouse-down/mouse-up sequence.
    var iconFrames: [String: CGRect] = [:]
    private var hoverClearWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?

    /// The iOS-springboard-style "jiggle" edit mode — entered by
    /// long-pressing any taskbar icon (see `TaskButtonView` and its
    /// siblings' `.onLongPressGesture`), left via the taskbar's own "Terminé"
    /// button or the Escape key (`ShortcutsManager`). While active, a tap on
    /// an icon opens a file picker to assign it a custom image instead of
    /// launching/raising the app.
    ///
    /// Leaving edit mode is also what commits `pendingIconOrder` to disk
    /// (see its own doc comment) — every drag during the session is a pure
    /// in-memory preview until this flips back to `false`.
    var isEditingIcons = false {
        didSet {
            guard oldValue == true, isEditingIcons == false else { return }
            commitPendingIconOrder()
        }
    }

    /// A live, in-memory-only reordering while dragging icons around in
    /// edit mode — every entry's bundle identifier, in the order being
    /// previewed. `nil` means "no drag has happened yet this edit session,
    /// just show the real (disk) order". Kept separate from actually
    /// writing to `DockPinnedAppsStore` (what `reorder` used to do
    /// directly) because that write happens on *every* icon the drag
    /// crosses — real-time visual feedback needs something far cheaper
    /// than a disk write each time, and only ever writing once, when edit
    /// mode ends (`commitPendingIconOrder`), is exactly that.
    private var pendingIconOrder: [String]?

    /// Bumped whenever a custom icon is assigned or removed — `IconOverrideStore`
    /// itself is a plain enum backed by files on disk, not something SwiftUI's
    /// Observation can see writes to on its own, so button views read this
    /// counter (via `resolvedIcon`) to know to re-fetch instead.
    private(set) var iconOverrideVersion = 0

    /// The icon a task/launcher/grouped button should actually draw: a
    /// custom override if one's been assigned, otherwise `fallback` (the
    /// app's own icon, however that button normally resolves it).
    func resolvedIcon(bundleIdentifier: String?, fallback: NSImage?) -> NSImage? {
        _ = iconOverrideVersion
        return IconOverrideStore.customIcon(for: bundleIdentifier) ?? fallback
    }

    /// Presents a plain `NSOpenPanel` (synchronous, needs no SwiftUI state
    /// of its own) for the user to pick a replacement image, and stores it
    /// as that app's custom icon if they choose one.
    func presentIconPicker(for bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L("icon_picker.title")

        // This app runs as an accessory (`.accessory`, no Dock icon, never
        // the "active app") so its own always-on-top bar behaves like a
        // real taskbar — but that's also why the panel's sidebar (Favoris,
        // iCloud Drive, …) didn't respond to clicks at all: an accessory
        // app's modal panel never properly becomes the active app's own
        // key window, which the sidebar's click handling apparently needs,
        // even though the main file grid worked fine regardless. Briefly
        // going `.regular` for just this panel's lifetime fixes that
        // without changing how the app behaves the rest of the time.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        IconOverrideStore.setCustomIcon(image, for: bundleIdentifier)
        iconOverrideVersion += 1
    }

    func hasCustomIcon(bundleIdentifier: String?) -> Bool {
        _ = iconOverrideVersion
        return IconOverrideStore.customIcon(for: bundleIdentifier) != nil
    }

    func restoreOriginalIcon(for bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        IconOverrideStore.removeCustomIcon(for: bundleIdentifier)
        iconOverrideVersion += 1
    }

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

        for pinned in orderedPinnedApps {
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

    /// Asks for confirmation first — unlike pinning, unpinning removes
    /// something the user (or a previous session) deliberately put there,
    /// and it's one click away in a context menu with no undo.
    func unpin(url: URL, bundleIdentifier: String?, displayName: String) {
        guard confirmUnpin(displayName: displayName) else { return }
        DockPinnedAppsStore.unpin(url: url, bundleIdentifier: bundleIdentifier)
        refreshPinnedApps()
    }

    private func confirmUnpin(displayName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("alert.unpin.title", ["name": displayName])
        alert.informativeText = L("alert.unpin.message")
        alert.addButton(withTitle: L("taskbar.unpin"))
        alert.addButton(withTitle: L("button.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Convenience for task buttons, which only know a running window's
    /// pid — looks up its app bundle to pin/unpin by.
    func togglePin(pid: pid_t, bundleIdentifier: String?, displayName: String) {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
        if isPinned(bundleIdentifier: bundleIdentifier) {
            unpin(url: url, bundleIdentifier: bundleIdentifier, displayName: displayName)
        } else {
            pin(url: url, displayName: displayName)
        }
    }

    /// Drag-and-drop reordering of taskbar icons — a pure in-memory preview
    /// (`pendingIconOrder`) while `isEditingIcons` is on; nothing reaches
    /// the real Dock until edit mode actually ends (`commitPendingIconOrder`).
    /// Moves `draggedBundleIdentifier` to sit at `droppedOnBundleIdentifier`'s
    /// position among everything currently shown in the taskbar. Anything
    /// touched by the drag that wasn't already pinned becomes pinned once
    /// committed — only pinned apps have a persistent position, so that's
    /// the only way a manual reorder can "stick".
    func reorder(draggedBundleIdentifier: String, droppedOnBundleIdentifier: String) {
        guard draggedBundleIdentifier != droppedOnBundleIdentifier else { return }

        var order = currentEntryBundleIdentifiers()
        guard let fromIndex = order.firstIndex(of: draggedBundleIdentifier),
              let originalTargetIndex = order.firstIndex(of: droppedOnBundleIdentifier) else { return }
        // Dragging onto the item immediately to your right, then always
        // inserting *before* the target, is a no-op for that one specific
        // case — the dragged item was already sitting right before it.
        // Whether the drag moved forward or backward decides which side of
        // the (now-shifted) target to land on instead, so an adjacent swap
        // actually swaps regardless of direction.
        let movingForward = fromIndex < originalTargetIndex

        order.remove(at: fromIndex)
        guard let toIndex = order.firstIndex(of: droppedOnBundleIdentifier) else { return }
        let insertionIndex = movingForward ? toIndex + 1 : toIndex
        order.insert(draggedBundleIdentifier, at: insertionIndex)

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            pendingIconOrder = order
        }
    }

    /// Every taskbar entry's bundle identifier, in the order they're
    /// currently shown (pinned launchers first in Dock order, then any
    /// other running app) — the ordering a drag operates on. Reflects
    /// `pendingIconOrder` automatically, since `entries` (what this reads)
    /// is itself built from `orderedPinnedApps`.
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

    /// `pinnedApps` in `pendingIconOrder`'s order when a drag preview is
    /// active, otherwise just `pinnedApps` unchanged — what `entries`
    /// actually renders from. Built with the exact same resolution
    /// `applyOrder` uses to write to disk (a bundle identifier is either
    /// already pinned, or a currently-running app being pinned for the
    /// first time by this drag), so the live preview always looks exactly
    /// like what committing it will produce.
    private var orderedPinnedApps: [PinnedApp] {
        guard let pendingIconOrder else { return pinnedApps }
        return Self.resolvePinnedApps(for: pendingIconOrder, existingPinned: pinnedApps)
    }

    private static func resolvePinnedApps(for bundleIdentifiers: [String], existingPinned: [PinnedApp]) -> [PinnedApp] {
        var resolved: [PinnedApp] = []
        for bundleIdentifier in bundleIdentifiers {
            if let existing = existingPinned.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                resolved.append(existing)
            } else if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
                      let url = running.bundleURL {
                let name = running.localizedName ?? url.deletingPathExtension().lastPathComponent
                resolved.append(PinnedApp(url: url, displayName: name, bundleIdentifier: bundleIdentifier, rawEntry: nil))
            }
        }
        return resolved
    }

    /// Writes `pendingIconOrder` (if any drag actually happened this edit
    /// session) to the real Dock, exactly once — called from
    /// `isEditingIcons`'s own `didSet` when edit mode ends.
    private func commitPendingIconOrder() {
        guard let pendingIconOrder else { return }
        self.pendingIconOrder = nil
        DockPinnedAppsStore.reorder(to: Self.resolvePinnedApps(for: pendingIconOrder, existingPinned: pinnedApps))
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

    /// Real `autohide` (see `DockController`) reclaims the Dock's screen
    /// space entirely, so a maximized/zoomed window can size itself all the
    /// way to the bottom of the screen — right where our panel sits. This
    /// nudges any window on the Dock's screen whose bottom edge dips into
    /// the panel's area back above it, by shrinking its height (never
    /// moving its top edge), the same outcome a real reserved `visibleFrame`
    /// would have produced. Cheap to call frequently: it's a no-op AX read
    /// for every window that isn't currently overlapping.
    func reclaimReservedSpace(panelHeight: CGFloat) {
        guard AXIsProcessTrusted(),
              let dockScreen = DockController.dockScreen,
              let primaryScreen = NSScreen.screens.first else { return }

        // AX coordinates are global, top-left-of-the-primary-screen-origin,
        // Y increasing downward — flipping by the primary screen's height
        // converts a Y into the bottom-left-origin AppKit space `NSScreen`
        // frames use, without needing to know which physical screen a
        // window is on ahead of time.
        let primaryHeight = primaryScreen.frame.height
        let reservedTop = dockScreen.frame.minY + panelHeight

        for window in windows where !window.isMinimized {
            guard
                let axPosition = Self.copyPointAttribute(window.axElement, kAXPositionAttribute),
                let axSize = Self.copySizeAttribute(window.axElement, kAXSizeAttribute)
            else { continue }

            let appKitFrame = CGRect(
                x: axPosition.x,
                y: primaryHeight - axPosition.y - axSize.height,
                width: axSize.width,
                height: axSize.height
            )
            // Only windows actually on the Dock's own screen can overlap
            // our panel — a window on another display might coincidentally
            // read a Y below `reservedTop` without being anywhere near it.
            guard dockScreen.frame.intersects(appKitFrame), appKitFrame.minY < reservedTop else { continue }

            let overlap = reservedTop - appKitFrame.minY
            let newHeight = axSize.height - overlap
            // Never shrink a window into uselessness — leaves genuinely
            // tiny/odd windows alone rather than fighting their own layout.
            guard newHeight >= 100 else { continue }

            var newSize = CGSize(width: axSize.width, height: newHeight)
            guard let sizeValue = AXValueCreate(.cgSize, &newSize) else { continue }
            AXUIElementSetAttributeValue(window.axElement, kAXSizeAttribute as CFString, sizeValue)
        }
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
        //
        // Root cause of a confirmed duplicate-entry bug (a single Claude
        // window appearing twice, one stuck "minimized"): `_AXUIElementGetWindow`
        // can transiently fail for one refresh cycle — observed happening
        // right as a native Open/Save panel sheet attaches to the window —
        // which makes `stableID` fall back to a `"pid-title"` id instead of
        // the usual `"cg-<CGWindowID>"` one for that single cycle. Once the
        // AX tree settles, the *same* physical window resolves back to its
        // normal `cg-…` id via the fresh scan above, but the old
        // `"pid-title"` entry never naturally goes away: its `axElement`
        // reference is still the same live, real window, so
        // `AXUIElementCopyAttributeValue` on it keeps succeeding forever,
        // endlessly re-adding it here as a second, separate, permanently
        // "stale" entry for a window that's actually still right there.
        // Recomputing the id fresh (instead of trusting the one it was
        // filed under originally) is what lets this self-correct: once
        // `_AXUIElementGetWindow` succeeds again, the recomputed id matches
        // the fresh scan's own `cg-…` id, `seenIDs` already has it, and
        // this stale copy is correctly dropped instead of kept forever.
        for previous in windows {
            guard runningPIDs.contains(previous.pid) else { continue } // app quit: drop it
            guard !seenIDs.contains(previous.id) else { continue } // already re-collected fresh

            var titleValue: CFTypeRef?
            let stillValid = AXUIElementCopyAttributeValue(previous.axElement, kAXTitleAttribute as CFString, &titleValue) == .success
            guard stillValid else { continue } // window truly closed: drop it

            let currentTitle = (titleValue as? String) ?? previous.title

            // Belt-and-suspenders: if this cycle's fresh scan already found
            // a *different*, genuinely live window for the same process
            // with the same title, treat this stale entry as that same
            // window under an old id — not a second, coincidentally
            // identically-titled window — regardless of what the id
            // recomputation below says. Needed because a stale
            // `AXUIElement` reference's private windowID lookup can fail
            // *permanently* for that specific reference, not just for one
            // transient cycle, in which case recomputing the id alone
            // keeps producing the same stale fallback id forever.
            let alreadyRepresented = collected.contains { $0.pid == previous.pid && $0.title == currentTitle }
            guard !alreadyRepresented else { continue }

            let recomputedID = Self.stableID(for: previous.axElement, pid: previous.pid, title: currentTitle)
            guard !seenIDs.contains(recomputedID) else { continue } // same window as one already found fresh, just under its old id

            let reAdded = AppWindow(
                id: recomputedID,
                axElement: previous.axElement,
                pid: previous.pid,
                bundleIdentifier: previous.bundleIdentifier,
                title: currentTitle,
                appName: previous.appName,
                appIcon: previous.appIcon,
                isMinimized: Self.copyBoolAttribute(previous.axElement, kAXMinimizedAttribute) ?? true
            )
            collected.append(reAdded)
            seenIDs.insert(recomputedID)
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
        LaunchHistoryStore.recordLaunch(bundleIdentifier: pinned.bundleIdentifier)
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

    /// "Minimize all": minimizes whatever isn't already minimized. A no-op
    /// (not a "restore everything" toggle any more) when everything's
    /// already minimized — pressing it again shouldn't bring windows back.
    func minimizeAll() {
        let toMinimize = windows.filter { !$0.isMinimized }
        guard !toMinimize.isEmpty else { return }
        for window in toMinimize {
            AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
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

        // Some apps (Electron ones especially — this is how a single-window
        // Claude could show up "grouped" with a phantom second entry)
        // expose a hidden helper/GPU-process window via AX that has no
        // title of its own, so `title` silently fell back to the app's
        // name instead — making it look like a second, identically-named
        // real window. Those are reliably near-zero-size; a real window
        // never is. Only rejects when the size was actually readable, so
        // an app that genuinely doesn't expose `kAXSizeAttribute` for some
        // other reason isn't punished for it.
        if let size = copySizeAttribute(element, kAXSizeAttribute), size.width < 50 || size.height < 50 {
            return false
        }
        return true
    }

    private static func copySizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else { return nil }
        return size
    }

    private static func copyPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else { return nil }
        return point
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
