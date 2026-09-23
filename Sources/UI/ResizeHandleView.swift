import AppKit

/// A thin, invisible strip along the panel's top edge that lets the user
/// drag-resize the taskbar, like dragging the edge of a real Plasma panel.
/// Plain AppKit (not SwiftUI) — `DragGesture` + `@State` would need the
/// SwiftUI compiler-macro plugin this project intentionally avoids (see
/// `ShortcutsManager`), and a resize handle is a natural fit for AppKit
/// mouse tracking anyway.
final class ResizeHandleView: NSView {
    /// Called with the raw vertical pointer delta for each drag tick,
    /// already sign-corrected so positive means "grow the panel".
    var onDrag: ((CGFloat) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        // Just needs to be handled so mouseDragged events keep coming to us.
    }

    override func mouseDragged(with event: NSEvent) {
        // NSEvent.deltaY is positive when the pointer moves down the
        // screen; dragging the top edge UP should grow the panel, so we
        // flip the sign.
        onDrag?(-event.deltaY)
    }
}
