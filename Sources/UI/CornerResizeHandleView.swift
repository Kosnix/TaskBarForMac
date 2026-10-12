import AppKit

/// A small draggable grip in the start menu's top-right corner, for
/// resizing it like a real window — see `ResizeHandleView` for the same
/// idea applied to just the taskbar's height. This one drags on both axes
/// since the start menu anchors at its bottom-left corner (just above the
/// start button) and grows up/right from there.
final class CornerResizeHandleView: NSView {
    /// Called with the raw pointer delta for each drag tick, already
    /// sign-corrected so positive width/height means "grow the menu".
    var onDrag: ((_ dWidth: CGFloat, _ dHeight: CGFloat) -> Void)?

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

    override func draw(_ dirtyRect: NSRect) {
        // A minimal visible grip (three short diagonal strokes), so the
        // corner reads as draggable instead of being an invisible hotspot.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(1)
        let inset: CGFloat = 3
        for offset in stride(from: inset, to: bounds.width - inset, by: 4) {
            context.move(to: CGPoint(x: bounds.width - offset, y: inset))
            context.addLine(to: CGPoint(x: bounds.width - inset, y: offset))
        }
        context.strokePath()
    }

    override func mouseDown(with event: NSEvent) {
        // Just needs to be handled so mouseDragged events keep coming to us.
    }

    override func mouseDragged(with event: NSEvent) {
        // Anchored at the bottom-left: dragging right/up should grow the
        // menu, so width grows with +deltaX and height grows with -deltaY
        // (deltaY is positive moving *down* the screen).
        onDrag?(event.deltaX, -event.deltaY)
    }

    /// Same fix as `ResizeHandleView`'s.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
