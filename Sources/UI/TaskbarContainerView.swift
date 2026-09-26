import AppKit

/// `TaskbarPanel`'s content view. Shows the personalization menu
/// (`PersonalizationMenuBuilder`) on right-click — a plain `NSView`
/// override instead of SwiftUI's `.contextMenu`, since that path only
/// receives the click at all when nothing inside the SwiftUI content
/// (task buttons, which have their own per-item context menus) already
/// claimed it, i.e. exactly when the click landed on empty bar background.
final class TaskbarContainerView: NSView {
    var themeStore: ThemeStore?

    override func rightMouseDown(with event: NSEvent) {
        guard let themeStore else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = PersonalizationMenuBuilder.build(themeStore: themeStore)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
