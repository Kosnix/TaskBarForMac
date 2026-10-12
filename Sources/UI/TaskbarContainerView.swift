import AppKit

// Private WindowServer calls (stable for over a decade, used by most
// utilities that need this) — see `allowCursorWhileInactive`.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// `TaskbarPanel`'s content view. Shows the personalization menu
/// (`PersonalizationMenuBuilder`) on right-click — a plain `NSView`
/// override instead of SwiftUI's `.contextMenu`, since that path only
/// receives the click at all when nothing inside the SwiftUI content
/// (task buttons, which have their own per-item context menus) already
/// claimed it, i.e. exactly when the click landed on empty bar background.
final class TaskbarContainerView: NSView {
    var themeStore: ThemeStore?
    var windowManager: WindowManager?
    var resizeStrip: BarResizeStripView?
    var barID = ""

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

    /// The part the arrow assertions below were missing: WindowServer
    /// ignores a cursor change from a background app unless its connection
    /// says it's allowed to set one, so every `NSCursor.arrow.set()` here
    /// was silently dropped and the resize cursor of the window underneath
    /// stayed on screen over the bar.
    private func allowCursorWhileInactive() {
        let connection = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        allowCursorWhileInactive()
    }

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

    /// The arrow everywhere on the bar except over the resize strip while
    /// it's live (icon edit mode), where it's the resize cursor.
    private func setCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if resizeStrip?.isLive(at: point) == true {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }
    override func mouseEntered(with event: NSEvent) {
        windowManager?.activeBarID = barID
        setCursor(for: event)
    }
    override func mouseMoved(with event: NSEvent) { setCursor(for: event) }
}
