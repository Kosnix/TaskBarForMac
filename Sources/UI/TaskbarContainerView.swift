import AppKit

/// `TaskbarPanel`'s content view. Shows the personalization menu
/// (`PersonalizationMenuBuilder`) on right-click — a plain `NSView`
/// override instead of SwiftUI's `.contextMenu`, since that path only
/// receives the click at all when nothing inside the SwiftUI content
/// (task buttons, which have their own per-item context menus) already
/// claimed it, i.e. exactly when the click landed on empty bar background.
final class TaskbarContainerView: NSView {
    var themeStore: ThemeStore?
    var windowManager: WindowManager?

    override func rightMouseDown(with event: NSEvent) {
        guard let themeStore else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = PersonalizationMenuBuilder.build(themeStore: themeStore, windowManager: windowManager)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Without this, the very first right-click while some other app is
    /// frontmost only brings this panel forward instead of opening the
    /// menu — same fix as `PressAndHoldView`'s, just for the bar's own
    /// right-click menu instead of an icon's click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Cursor

    /// This panel is `.nonactivatingPanel` and this app is an `.accessory`
    /// one, so it's almost never the active app — and an inactive app's
    /// cursor rects are ignored entirely, which lets whatever cursor the
    /// window *underneath* set (the resize arrows at the edge of a
    /// maximized window that runs right up to the bar, say) stay on screen
    /// over the bar itself. A tracking area with `.activeAlways` is the one
    /// mechanism that still fires while inactive, so the arrow gets
    /// asserted from there — on enter, on every move (so nothing else can
    /// swap it back in between), and on `cursorUpdate`.
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
}
