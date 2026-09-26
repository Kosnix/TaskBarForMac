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
                windows11ShowPinnedOnly = false
                windows7ShowPinnedOnly = false
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

    /// The Windows 11 layout's "Épinglé" toggle (see
    /// `Windows11StartMenuView`) — irrelevant to the Kickoff layout, kept
    /// here rather than view-local `@State` for the same reason every
    /// other piece of menu state is (see this type's own doc comment).
    /// Defaults off: the layout shows every app by default, not just the
    /// Dock's pinned ones.
    var windows11ShowPinnedOnly = false {
        didSet { selectedIndex = 0 }
    }

    /// The Windows 7 layout's "Épinglé" toggle (see
    /// `Windows7StartMenuView`) — defaults off: the list shows every
    /// installed app, most-recently-launched first, rather than just the
    /// Dock's pinned ones.
    var windows7ShowPinnedOnly = false {
        didSet { selectedIndex = 0 }
    }

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
        didSet { selectedIndex = 0 }
    }
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
