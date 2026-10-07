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
    /// The display the window's center is on — only worked out when there's
    /// more than one display (see `WindowManager.displayID(of:)`).
    var displayID: CGDirectDisplayID? = nil
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
    /// The bar the pointer is on (`TaskbarPanel.barID`) — the hover popup
    /// belongs to that one, not to every bar showing the same app.
    var activeBarID = "primary"
    /// The thumbnail card the mouse is over in the hover preview strip.
    var hoveredPreviewWindowID: String?

    private static let trashFolderName: String = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? "Trash"
    }()

    /// Whether a Finder window showing the Trash is open (minimized or not)
    /// — the taskbar's trash icon opens its lid while this is true. Finder
    /// titles such a window with the Trash's localized name ("Trash",
    /// "Corbeille", …).
    var isTrashOpen: Bool {
        windows.contains { $0.bundleIdentifier == "com.apple.finder" && $0.title == Self.trashFolderName }
    }

    /// The taskbar icon the mouse button is currently held down on (same id
    /// scheme as `hoveredWindowID`/`hoveredGroupID`, see `iconPressAndHold`) —
    /// it shrinks while pressed, like on Windows.
    var pressedIconID: String?

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
            editModeChangedAt = Date()
            guard oldValue == true, isEditingIcons == false else { return }
            commitPendingIconOrder()
        }
    }

    /// When `isEditingIcons` last flipped — what the wiggle eases in/out from.
    @ObservationIgnored private(set) var editModeChangedAt = Date.distantPast

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

    /// Bumped whenever a custom display name is assigned or removed — same
    /// role `iconOverrideVersion` plays for `IconOverrideStore`.
    private(set) var displayNameOverrideVersion = 0

    /// The name a task/launcher/grouped button, or any start menu, should
    /// actually show: a custom override if one's been assigned via
    /// "Rename", otherwise `fallback` (the app's own real name).
    func resolvedDisplayName(bundleIdentifier: String?, fallback: String) -> String {
        _ = displayNameOverrideVersion
        return AppDisplayNameStore.customName(for: bundleIdentifier) ?? fallback
    }

    func hasCustomDisplayName(bundleIdentifier: String?) -> Bool {
        _ = displayNameOverrideVersion
        return AppDisplayNameStore.customName(for: bundleIdentifier) != nil
    }

    /// Every start menu's own search matches against this instead of just
    /// one name or the other — a rename is an *additional* way to find an
    /// app, not a replacement for searching by its real name, which still
    /// has to work even after a custom one's been assigned.
    func matchesSearch(bundleIdentifier: String?, realName: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if realName.localizedCaseInsensitiveContains(query) { return true }
        guard let custom = AppDisplayNameStore.customName(for: bundleIdentifier) else { return false }
        return custom.localizedCaseInsensitiveContains(query)
    }

    func restoreOriginalDisplayName(for bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        AppDisplayNameStore.removeCustomName(for: bundleIdentifier)
        displayNameOverrideVersion += 1
    }

    /// A plain `NSAlert` with a text field, same "no SwiftUI sheet
    /// infrastructure needed for a single one-off prompt" reasoning
    /// `presentIconPicker` already uses for its own `NSOpenPanel` — this
    /// only ever changes how *this app* labels something, never the app's
    /// real name anywhere else (Finder, Spotlight, its own window titles).
    func promptRename(bundleIdentifier: String?, currentName: String) {
        guard let bundleIdentifier else { return }
        let alert = NSAlert()
        alert.messageText = L("rename.title", ["name": currentName])
        alert.informativeText = L("rename.message")
        alert.addButton(withTitle: L("rename.confirm"))
        alert.addButton(withTitle: L("button.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = currentName
        field.usesSingleLineMode = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // Same reasoning as `presentIconPicker`: this app runs as an
        // `.accessory` (no Dock icon, never the "active app"), so a modal
        // alert doesn't reliably become key/focused without briefly
        // promoting to `.regular` for its lifetime.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        AppDisplayNameStore.setCustomName(newName, for: bundleIdentifier)
        displayNameOverrideVersion += 1
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
    var entries: [TaskbarEntry] { entries(for: nil) }

    /// Which windows one bar shows when there's a bar per screen: its own
    /// screen's, plus — on the main bar only — minimized ones and any whose
    /// screen couldn't be told, and the pinned launchers.
    struct BarScope {
        let displayID: CGDirectDisplayID?
        let isPrimary: Bool
    }

    /// `nil` scope: everything, on one bar.
    func entries(for scope: BarScope?, grouped: Bool = true) -> [TaskbarEntry] {
        var result: [TaskbarEntry] = []
        var consumedWindowIDs = Set<String>()
        let windows = scope.map { scope in
            self.windows.filter { window in
                window.displayID == scope.displayID || (scope.isPrimary && (window.displayID == nil || window.isMinimized))
            }
        } ?? self.windows

        for pinned in (scope?.isPrimary ?? true) ? orderedPinnedApps : [] {
            let matches = windows.filter { $0.bundleIdentifier != nil && $0.bundleIdentifier == pinned.bundleIdentifier }
            if matches.isEmpty {
                result.append(.launcher(pinned))
            } else {
                result.append(contentsOf: Self.groupedEntries(for: matches, grouped: grouped))
                consumedWindowIDs.formUnion(matches.map(\.id))
            }
        }

        let remaining = windows.filter { !consumedWindowIDs.contains($0.id) }
        result.append(contentsOf: Self.groupedEntries(for: remaining, grouped: grouped))
        return result
    }

    /// Splits a set of windows into entries, grouping same-app windows
    /// (2+) under one `.group` entry, keeping a lone window as `.window`.
    private static func groupedEntries(for windows: [AppWindow], grouped: Bool = true) -> [TaskbarEntry] {
        guard grouped else { return windows.map { .window($0) } }
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
        // Only reached when the actual *set* of pinned ids changed (a real
        // pin/unpin), never on the periodic no-op refresh — safe to always
        // animate, unlike `refresh()`'s own equivalent guard, which needs
        // to tell a genuine add/remove apart from routine per-refresh
        // churn (title/minimized-state changes) itself.
        if updated.map(\.id) != pinnedApps.map(\.id) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                pinnedApps = updated
            }
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

    /// No confirmation dialog — unpinning is one click away in a context
    /// menu but easily undone (drag the app back onto the bar, or re-pin
    /// from the start menu), and `NSAlert.runModal()`'s own nested run loop
    /// was what kept the removal's `withAnimation` (see `refreshPinnedApps`)
    /// from actually animating: by the time the alert returned and the
    /// real mutation ran, the transaction context it needed was gone.
    func unpin(url: URL, bundleIdentifier: String?, displayName: String) {
        DockPinnedAppsStore.unpin(url: url, bundleIdentifier: bundleIdentifier)
        refreshPinnedApps()
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
    /// Moves `draggedBundleIdentifier` to sit just before or after
    /// `droppedOnBundleIdentifier`, per `insertBefore` — decided by
    /// `PressAndHoldView` from which side of the target the cursor is
    /// physically on, not from comparing indices (see its own doc comment
    /// for why that used to make an adjacent swap oscillate forever). Only
    /// pinned apps have a persistent position, so anything touched by the
    /// drag that wasn't already pinned becomes pinned once committed — that
    /// is what makes a manual reorder "stick".
    func reorder(draggedBundleIdentifier: String, droppedOnBundleIdentifier: String, insertBefore: Bool) {
        guard draggedBundleIdentifier != droppedOnBundleIdentifier else { return }

        let originalOrder = currentEntryBundleIdentifiers()
        var order = originalOrder
        guard let fromIndex = order.firstIndex(of: draggedBundleIdentifier),
              order.contains(droppedOnBundleIdentifier) else { return }

        order.remove(at: fromIndex)
        guard let toIndex = order.firstIndex(of: droppedOnBundleIdentifier) else { return }
        let insertionIndex = insertBefore ? toIndex : toIndex + 1
        order.insert(draggedBundleIdentifier, at: insertionIndex)

        // `PressAndHoldView` calls this on every drag tick that lands over a
        // (possibly repeated) target, not just once — bailing out here when
        // nothing would actually change is what makes that safe, instead of
        // needing the caller to guess in advance whether a given target is
        // "new". That in turn is what makes reversing a drag work: passing
        // over an icon, continuing past it, then coming straight back to
        // the very same icon needs to trigger a *second*, different reorder
        // against that identical target — something a plain "did the target
        // change since last time" guard on the caller's side can't tell
        // apart from hovering it without moving at all.
        guard order != originalOrder else { return }

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
                resolved.append(PinnedApp(url: url, displayName: name, bundleIdentifier: bundleIdentifier, rawEntry: nil, icon: running.icon ?? NSWorkspace.shared.icon(forFile: url.path)))
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
    func reclaimReservedSpace(panelHeight: CGFloat, screens barScreens: [NSScreen]) {
        guard AXIsProcessTrusted(), !barScreens.isEmpty,
              let primaryScreen = NSScreen.screens.first else { return }

        // AX coordinates are global, top-left-of-the-primary-screen-origin,
        // Y increasing downward — flipping by the primary screen's height
        // converts a Y into the bottom-left-origin AppKit space `NSScreen`
        // frames use, without needing to know which physical screen a
        // window is on ahead of time.
        let primaryHeight = primaryScreen.frame.height

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
            // Only windows actually on a screen with a bar can overlap it —
            // a window on another display might coincidentally read a Y
            // below `reservedTop` without being anywhere near one.
            guard let barScreen = barScreens.first(where: { $0.frame.intersects(appKitFrame) }) else { continue }
            let reservedTop = barScreen.frame.minY + panelHeight
            guard appKitFrame.minY < reservedTop else { continue }

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

    /// The display a window's center falls on, from its Accessibility
    /// frame (top-left origin, Y down). `nil` with a single display, where
    /// there's nothing to tell apart.
    private static func displayID(of axWindow: AXUIElement) -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        guard screens.count > 1, let primary = screens.first,
              let origin = copyPointAttribute(axWindow, kAXPositionAttribute),
              let size = copySizeAttribute(axWindow, kAXSizeAttribute) else { return nil }
        let center = CGPoint(x: origin.x + size.width / 2, y: primary.frame.height - (origin.y + size.height / 2))
        return screens.first { $0.frame.contains(center) }?.displayID
    }

    func refresh() {
        // Apps hidden for the desktop peek are about to come straight back —
        // not worth redrawing the bar around them for that moment.
        guard !isPeekingDesktop else { return }
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
                let ownTitle = Self.copyStringAttribute(axWindow, kAXTitleAttribute)
                // An *empty* title (Photos, for one, reports "" for its main
                // window) is a real window whose title just isn't exposed,
                // not a phantom — it takes the app's name like a missing
                // title does, but unlike a missing one it has to prove it's
                // a genuine standard window first (see `isRealWindow`).
                let titleIsEmpty = ownTitle?.isEmpty == true
                let title = (titleIsEmpty ? nil : ownTitle) ?? app.localizedName ?? L("window.untitled")
                guard Self.isRealWindow(axWindow, title: title, requiresStandardSubrole: titleIsEmpty, bundleIdentifier: app.bundleIdentifier) else { continue }

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
                    isMinimized: minimized,
                    displayID: minimized ? nil : Self.displayID(of: axWindow)
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

            let currentTitle = (titleValue as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previous.title

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

        // Any window going from minimized back to open — however that
        // happened — ends the minimize-all button's restore memory.
        if let remembered = minimizedByButton {
            let wasMinimized = Dictionary(windows.map { ($0.id, $0.isMinimized) }, uniquingKeysWith: { first, _ in first })
            var restoredSomewhere = collected.contains { wasMinimized[$0.id] == true && !$0.isMinimized }
            // Also asks the remembered windows themselves, not just ids
            // seen across two refreshes: an id can change when a window is
            // minimized, which would make a restore invisible to the
            // comparison above. Skipped right after the press, since AX can
            // still report a window as open for the length of its minimize
            // animation.
            if !restoredSomewhere, Date().timeIntervalSince(minimizedByButtonAt) > 1.5 {
                restoredSomewhere = remembered.contains { Self.copyBoolAttribute($0, kAXMinimizedAttribute) == false }
            }
            if restoredSomewhere { minimizedByButton = nil }
        }

        // Whether this refresh introduces or removes a window for an app
        // that isn't pinned — the exact "an icon is joining/leaving the
        // row" cases `TaskbarView`'s `.taskbarAppearance` transition is
        // for (a pinned app's own icon just changes state in place, so
        // it's excluded — see that transition's own doc comment).
        // `.animation(_:value:)` on the taskbar's own view turned out not
        // to reliably catch a transition driven by a *different* object's
        // (this one's) state mutation — wrapping the mutation itself in
        // `withAnimation` here, only when it's actually warranted, is the
        // reliable way. Not unconditionally, since that would also animate
        // every incidental refresh (a title update, a minimized flag
        // flipping) that has nothing to do with an icon appearing/leaving.
        let previousIDs = Set(windows.map(\.id))
        let newIDs = Set(collected.map(\.id))
        let introducesNewUnpinnedWindow = collected.contains { window in
            !previousIDs.contains(window.id) && !isPinned(bundleIdentifier: window.bundleIdentifier)
        }
        let removesUnpinnedWindow = windows.contains { window in
            !newIDs.contains(window.id) && !isPinned(bundleIdentifier: window.bundleIdentifier)
        }

        if introducesNewUnpinnedWindow || removesUnpinnedWindow {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                windows = collected
            }
        } else {
            windows = collected
        }

        // An app that was flagged "stuck" (see `closeAll`/`close`'s own
        // stuck-check) but no longer has any window at all has since quit
        // on its own — nothing left to force-quit, so the taskbar's
        // context menu shouldn't keep offering to.
        if !stuckCloseAttempts.isEmpty {
            let stillPresent = Set(collected.map { $0.bundleIdentifier ?? "pid-\($0.pid)" })
            stuckCloseAttempts.formIntersection(stillPresent)
        }
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
    /// traffic-light button performs), rather than quitting the app. A
    /// soft request, same as clicking that button yourself: an app with
    /// unsaved changes can still show its own "Save?" dialog and ignore
    /// this entirely, which is exactly the case `scheduleStuckCloseCheck`
    /// exists to catch.
    func close(_ window: AppWindow) {
        let key = window.bundleIdentifier ?? "pid-\(window.pid)"
        var closeButton: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.axElement, kAXCloseButtonAttribute as CFString, &closeButton)
        if result == .success, let closeButton {
            AXUIElementPerformAction((closeButton as! AXUIElement), kAXPressAction as CFString)
        }
        refresh()
        scheduleStuckCloseCheck(key: key, pid: window.pid)
    }

    /// "Close All" on a grouped task button — the same soft, one-at-a-time
    /// AX close request `close(_:)` sends for a single window, just for
    /// every window that app currently has open.
    func closeAll(bundleIdentifier: String, windows: [AppWindow]) {
        for window in windows {
            var closeButton: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window.axElement, kAXCloseButtonAttribute as CFString, &closeButton)
            if result == .success, let closeButton {
                AXUIElementPerformAction((closeButton as! AXUIElement), kAXPressAction as CFString)
            }
        }
        refresh()
        guard let pid = windows.first?.pid else { return }
        scheduleStuckCloseCheck(key: bundleIdentifier, pid: pid)
    }

    /// Bundle identifiers (or synthetic `pid-…` keys, matching
    /// `groupedEntries`'s own) whose close was already requested and
    /// didn't actually get rid of every window within the grace period
    /// below — the taskbar's context menu offers "Force Quit" for these,
    /// instead of leaving someone to just keep clicking "Close" against an
    /// app that isn't responding to it. Cleared once the app genuinely has
    /// no windows left (see `refresh()`) or is force-quit.
    private(set) var stuckCloseAttempts: Set<String> = []

    private static let stuckCloseGracePeriod: TimeInterval = 1.5

    private func scheduleStuckCloseCheck(key: String, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stuckCloseGracePeriod) { [weak self] in
            guard let self else { return }
            let stillHasWindow = self.windows.contains { ($0.bundleIdentifier ?? "pid-\($0.pid)") == key }
            if stillHasWindow {
                self.stuckCloseAttempts.insert(key)
            }
        }
    }

    func isCloseStuck(bundleIdentifier: String?, pid: pid_t) -> Bool {
        let key = bundleIdentifier ?? "pid-\(pid)"
        return stuckCloseAttempts.contains(key)
    }

    /// Kills the process outright (`SIGKILL` via `NSRunningApplication`,
    /// not the graceful AX close every other action here uses) — only ever
    /// offered once a normal close has already been tried and didn't work.
    func forceQuit(bundleIdentifier: String?, pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
        stuckCloseAttempts.remove(bundleIdentifier ?? "pid-\(pid)")
        refresh()
    }

    /// "Minimize all": minimizes whatever isn't already minimized. A no-op
    /// when everything's already minimized. What the ⌘⌥D shortcut and the
    /// drag-hover spring-load use — they never restore anything; only the
    /// bar's own button does, via `toggleMinimizeAll()`.
    // MARK: - Desktop peek

    /// Windows' "Aero Peek" on the show-desktop strip: resting the pointer
    /// on the minimize-all button for a moment hides every app so the
    /// desktop shows through; moving off brings them all back. Hiding apps
    /// (not minimizing windows) is what makes it instant and leaves nothing
    /// to undo — `unhide` restores them exactly as they were.
    private(set) var isPeekingDesktop = false
    private var peekedApps: [NSRunningApplication] = []
    private var peekFrontmost: NSRunningApplication?
    private var peekWorkItem: DispatchWorkItem?
    private static let peekDelay: TimeInterval = 0.5

    func setDesktopPeek(_ active: Bool) {
        peekWorkItem?.cancel()
        peekWorkItem = nil
        if active {
            let work = DispatchWorkItem { [weak self] in self?.beginDesktopPeek() }
            peekWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDelay, execute: work)
        } else {
            endDesktopPeek(restoringFocus: true)
        }
    }

    private func beginDesktopPeek() {
        guard !isPeekingDesktop, !isEditingIcons else { return }
        peekFrontmost = NSWorkspace.shared.frontmostApplication
        peekedApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard !peekedApps.isEmpty else { return }
        isPeekingDesktop = true
        peekedApps.forEach { $0.hide() }
    }

    /// Brings the hidden apps back. `restoringFocus: false` is for a click
    /// that's about to minimize everything anyway.
    func endDesktopPeek(restoringFocus: Bool) {
        peekWorkItem?.cancel()
        peekWorkItem = nil
        guard isPeekingDesktop else { return }
        isPeekingDesktop = false
        peekedApps.forEach { $0.unhide() }
        peekedApps = []
        if restoringFocus { peekFrontmost?.activate() }
        peekFrontmost = nil
        refresh()
    }

    func minimizeAll() {
        let toMinimize = windows.filter { !$0.isMinimized }
        guard !toMinimize.isEmpty else { return }
        for window in toMinimize {
            AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        }
        refresh()
    }

    /// Exactly the windows the minimize-all *button* last minimized, or
    /// `nil` once there's nothing worth restoring. Held as the windows'
    /// own Accessibility elements rather than ids: an id can change once a
    /// window is minimized, which left this unable to recognize its own
    /// windows again. Cleared by `refresh()` the moment any window comes
    /// back from minimized by any route at all (the bar, the Dock, ⌘Tab,
    /// the app itself) — so pressing the button again never undoes an
    /// arrangement the user has since started rebuilding by hand.
    private var minimizedByButton: [AXUIElement]?
    private var minimizedByButtonAt = Date.distantPast

    /// The minimize-all button: first press minimizes everything open and
    /// remembers which windows that was; a second press — if nothing has
    /// been restored in between (see `minimizedByButton`) — restores just
    /// those windows. Windows that were already minimized beforehand were
    /// never part of the set, and ones closed since are simply gone. With
    /// everything already minimized and nothing remembered, it restores
    /// every window instead of doing nothing.
    func toggleMinimizeAll() {
        // Judge against the real current state, not whatever the last
        // 2-second poll saw — a restore done by hand just before this press
        // would otherwise still look like it hadn't happened.
        refresh()

        if let remembered = minimizedByButton {
            minimizedByButton = nil
            let toRestore = remembered.filter { Self.copyBoolAttribute($0, kAXMinimizedAttribute) == true }
            // Every remembered window has since been closed: nothing to
            // bring back, so this press should minimize like a fresh one
            // rather than silently do nothing.
            if !toRestore.isEmpty {
                for element in toRestore {
                    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                }
                refresh()
                return
            }
        }
        let toMinimize = windows.filter { !$0.isMinimized }
        if toMinimize.isEmpty {
            guard !windows.isEmpty else { return }
            for window in windows {
                AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
            refresh()
            return
        }
        for window in toMinimize {
            AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        }
        minimizedByButton = toMinimize.map(\.axElement)
        minimizedByButtonAt = Date()
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

    private static func isRealWindow(_ element: AXUIElement, title: String, requiresStandardSubrole: Bool, bundleIdentifier: String?) -> Bool {
        // Filter out AX-visible but non-window artifacts (menus, popovers) that
        // sometimes surface an empty/system title.
        guard !title.isEmpty else { return false }

        // Finder is always running and always reports an AX window for the
        // desktop itself, even with zero actual Finder windows open — which
        // would otherwise make Finder look permanently "open" in the
        // taskbar. Only its real Finder-window subrole counts.
        if requiresStandardSubrole,
           (copyStringAttribute(element, kAXSubroleAttribute) ?? "") != (kAXStandardWindowSubrole as String) {
            return false
        }

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
