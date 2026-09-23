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
        // popover) and not on `TaskbarPanel` either — that one's left
        // alone deliberately, since the start button's own tap handler
        // already toggles `isPresented` and would otherwise fight with a
        // dismiss triggered here for the exact same click.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if !(event.window is StartMenuPanel) && !(event.window is TaskbarPanel) {
                self.isPresented = false
            }
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
