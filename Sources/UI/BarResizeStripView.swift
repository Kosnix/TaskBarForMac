import AppKit

/// A thin strip along the taskbar's top edge that resizes the bar's height
/// by dragging — only while icon edit mode is on (`WindowManager.isEditingIcons`);
/// otherwise it's invisible to the mouse, so a stray drag on the edge can't
/// change the bar by accident (the "Bar Size" slider in Settings is the
/// everyday control, backed by the same `panelHeightOverride`).
final class BarResizeStripView: NSView {
    weak var windowManager: WindowManager?
    weak var themeStore: ThemeStore?

    static let thickness: CGFloat = 8
    /// Same range as the Settings slider.
    private static let heightRange: ClosedRange<Double> = 22...160

    private var dragStartMouseY: CGFloat = 0
    private var dragStartHeight: Double = 0

    private var isEditing: Bool { windowManager?.isEditingIcons == true }

    /// True when `point` (in this view's superview's coordinates) is over
    /// the strip while it's live — the container uses it to leave the
    /// cursor to this view instead of forcing the arrow.
    func isLive(at point: NSPoint) -> Bool {
        isEditing && frame.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditing ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let themeStore else { return }
        dragStartMouseY = NSEvent.mouseLocation.y
        dragStartHeight = Double(themeStore.effectivePanelHeight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let themeStore else { return }
        // Screen coordinates (Y up): dragging up grows the bar, which is
        // anchored to the bottom of the screen. Window-relative coordinates
        // would shift under the cursor as the panel itself resizes.
        let delta = Double(NSEvent.mouseLocation.y - dragStartMouseY)
        let height = min(max(dragStartHeight + delta, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        themeStore.panelHeightOverride = height.rounded()
    }
}
