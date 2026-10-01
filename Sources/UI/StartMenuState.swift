import AppKit
import Observation

enum StartMenuFocusRegion {
    case grid
    case categories
}

/// Shared so both the start button (SwiftUI) and the global keyboard
/// shortcut (AppKit-side `ShortcutsManager`) can toggle the same popover.
@Observable
final class StartMenuState {
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            isPresented ? startWatchingForOutsideClicks() : stopWatchingForOutsideClicks()
            if !isPresented {
                // Every close should start the next open fresh, not still
                // filtered by whatever was typed last time.
                query = ""
                selectedCategory = nil
                focusedRegion = .grid
                launchpadPage = 0
                isEditingLaunchpad = false
                openLaunchpadFolderID = nil
                launchpadDragItemID = nil
                launchpadDragSourceFolderID = nil
                launchpadPendingOrder = nil
                launchpadMergeTargetID = nil
            }
            onPresentationChange?(isPresented)
        }
    }

    /// Set once by whoever owns `StartMenuPanel` (see `TaskbarPanel`), so
    /// this plain state object can drive that AppKit window's
    /// show/hide without needing to know about it directly.
    var onPresentationChange: ((Bool) -> Void)?
    var selectedIndex = 0
    var focusedRegion: StartMenuFocusRegion = .grid
    var selectedCategoryIndex = 0

    /// The start button's current frame, in `TaskbarView`'s own root
    /// coordinate space (top-left origin, Y down — see the `"taskbarRoot"`
    /// named coordinate space it publishes into via a `GeometryReader`
    /// background) — kept live so `startWatchingForOutsideClicks` can tell
    /// a click *on the button* apart from a click anywhere else on the bar,
    /// without needing to know about SwiftUI at all itself.
    var startButtonFrame: CGRect = .zero

    /// Whether the mouse is currently over the start button — drives its
    /// own `.hoverLift` (`TaskbarView.startButton(theme:)`), matching every
    /// other taskbar icon's hover effect.
    var isStartButtonHovered = false

    /// Which row (by whatever id its own list uses) the mouse is currently
    /// over, across every start-menu layout's own lists — a plain `.onHover`
    /// is safe here (unlike a taskbar icon's, see `IconPressGesture.swift`)
    /// since these rows don't drive an animated scale/shadow off this same
    /// state, just a static background tint.
    var hoveredRowID: String?

    /// What both the start button's tap and the global keyboard shortcut
    /// actually call, instead of toggling `isPresented` directly —
    /// `.realSpotlight` doesn't draw any menu of its own at all, it just
    /// hands off to the real system Spotlight and leaves this app's own
    /// panel closed.
    func toggleOrOpenSpotlight(style: StartMenuStyle) {
        if style == .realSpotlight {
            SpotlightTrigger.open()
            return
        }
        isPresented.toggle()
    }

    var query = "" {
        didSet {
            selectedIndex = 0
            launchpadPage = 0
        }
    }

    /// `LaunchpadStartMenuView`'s current page — searching always shows a
    /// single flat grid of matches (no paging), so this only matters while
    /// browsing normally; reset whenever a search starts (see `query`'s own
    /// `didSet`) or the menu closes, same as every other piece of
    /// per-session start-menu state.
    var launchpadPage = 0

    /// The iOS-springboard-style "jiggle" mode for `LaunchpadStartMenuView`
    /// specifically — separate from `WindowManager.isEditingIcons` (which
    /// is about the *taskbar's* pinned-icon order, a completely different
    /// list), even though it reuses the exact same `.wiggle()` visual.
    var isEditingLaunchpad = false

    /// Which folder (by its `LaunchpadItem.id`) is currently expanded, if
    /// any — `nil` means the main grid.
    var openLaunchpadFolderID: String?

    /// Which item is currently being dragged — set the moment its `.onDrag`
    /// fires, cleared once the native drag session ends (dropped or
    /// cancelled). The drag's own visual (the icon following the cursor) is
    /// entirely AppKit's own native drag image now — see
    /// `LaunchpadStartMenuView`'s doc comment on why this moved away from a
    /// hand-tracked "ghost" view.
    var launchpadDragItemID: String?

    /// Set alongside `launchpadDragItemID` only when the drag started on an
    /// app *inside* an open folder — lets a drop on the folder's own
    /// dimmed background (i.e. dragged out past the folder card's edge)
    /// know which folder to pull it back out of.
    var launchpadDragSourceFolderID: String?

    /// The live reorder preview while dragging — `nil` means "show the real
    /// (persisted) order". Mirrors `WindowManager.pendingIconOrder`'s own
    /// "preview only, commit once at drag end" split for the exact same
    /// reason: writing to `LaunchpadOrderStore` on every icon the drag
    /// crosses would be needless churn when only the *final* position
    /// actually needs to stick.
    var launchpadPendingOrder: [LaunchpadItem]?

    /// The item currently under the cursor closely enough to create/join a
    /// folder if dropped now — drives that target's own "about to merge"
    /// highlight.
    var launchpadMergeTargetID: String?

    /// The pending page-flip timer while a drag lingers over one of the
    /// grid's edge hot-zones (see `LaunchpadEdgeDropDelegate`) — plain
    /// bookkeeping, not view state, so it's excluded from `@Observable`
    /// tracking. Lives here (not on the drop delegate itself) because that
    /// delegate is a struct SwiftUI is free to recreate on every drag tick;
    /// this class instance is what actually persists across those ticks.
    @ObservationIgnored var launchpadEdgeHoverWorkItem: DispatchWorkItem?

    /// `LaunchpadOrderStore` is a plain, non-`@Observable` UserDefaults
    /// wrapper (matching `IconOverrideStore`'s own pattern) — bumped after
    /// every write so `LaunchpadStartMenuView`'s `items` (a computed
    /// property re-reading the store fresh each time) is known to need
    /// re-evaluating, the same role `WindowManager.iconOverrideVersion`
    /// plays for custom icons.
    private(set) var launchpadOrderVersion = 0
    func bumpLaunchpadOrderVersion() { launchpadOrderVersion += 1 }

    var selectedCategory: String? {
        didSet { selectedIndex = 0 }
    }

    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    /// SwiftUI's `.popover(isPresented:)` is supposed to dismiss itself on an
    /// outside click, but that relies on the presenting window taking part
    /// in normal window activation — our taskbar panel is a
    /// `.nonactivatingPanel` sitting at an unusually high window level
    /// (just above the Dock's), which that built-in dismissal doesn't
    /// reliably handle. Watching for the click ourselves and dismissing
    /// through the same `isPresented` flag is a lot more predictable than
    /// trying to coax AppKit's own mechanism into working here.
    private func startWatchingForOutsideClicks() {
        stopWatchingForOutsideClicks()
        // Global: a click that lands in another app entirely (the desktop,
        // Finder, any other window) — always "outside" the menu.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.isPresented = false
        }
        // Local: a click inside our own app, but not on the start menu
        // itself (`StartMenuPanel`, its own real window now — not a
        // popover), and not *specifically on the start button* within
        // `TaskbarPanel` — that one's left alone deliberately, since the
        // start button's own tap handler already toggles `isPresented` and
        // would otherwise fight with a dismiss triggered here for the exact
        // same click (this monitor's handler runs before SwiftUI's own
        // gesture recognition does, so it can't just check `isPresented`
        // and infer the click was the button's). Anywhere else on the bar —
        // a task icon, empty space, the minimize-all strip — should close
        // the menu like any other outside click, while still letting that
        // same click's own action (raising a window, etc.) proceed
        // normally, since this only ever *reads* the event, never consumes
        // it.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window is StartMenuPanel {
                return event
            }
            if event.window is TaskbarPanel {
                let windowHeight = event.window?.contentView?.bounds.height ?? 0
                // `event.locationInWindow` is AppKit's bottom-left-origin,
                // Y-up window space; `startButtonFrame` was captured in
                // SwiftUI's top-left-origin, Y-down space — flipping Y by
                // the window's own height converts between the two.
                let pointInSwiftUISpace = CGPoint(x: event.locationInWindow.x, y: windowHeight - event.locationInWindow.y)
                if self.startButtonFrame.contains(pointInSwiftUISpace) {
                    return event
                }
            }
            self.isPresented = false
            return event
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }
}
