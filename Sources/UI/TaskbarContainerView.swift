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
}
