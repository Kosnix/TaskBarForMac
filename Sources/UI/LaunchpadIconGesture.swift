import AppKit
import SwiftUI

/// One cell in the Launchpad grid's own tap/long-press/drag handling — a
/// raw AppKit `NSView`, not SwiftUI's `Button` + `.onLongPressGesture` +
/// `.onDrag`/`.onDrop`. That SwiftUI combination was tried first here and
/// turned out unusable: mixing `.onDrag` with a tap/long-press recognizer
/// on the same view is exactly the kind of gesture-composition conflict
/// this project had already hit once before for the taskbar's own icons
/// (see `IconPressGesture.swift`'s own doc comment) — which is *why* the
/// taskbar uses this same raw-AppKit approach instead.
///
/// This keeps that proven split — `mouseDown`/`mouseDragged`/`mouseUp`
/// tracking tap vs. long-press vs. "a real drag just started" — but for the
/// drag itself, hands off to AppKit's own native `NSDraggingSession`
/// (`beginDraggingSession(with:event:source:)`) instead of hand-tracking a
/// "ghost" view's position in SwiftUI state, which is what the very first
/// version of this file did and which went through three straight rounds
/// of position bugs (flying off on reorder, freezing from an animation
/// conflict, landing at a stale position on a second drag) — all of them
/// symptoms of reimplementing, by hand, exactly what native drag-and-drop
/// already does for free. A real `NSDraggingSession` is rendered and moved
/// by the window server itself, so there's no "current position" left for
/// this code to ever get wrong, because it never computes one.
///
/// Each cell is both a drag *source* (you can pick it up) and a drag
/// *destination* (something else can be dropped on it, to reorder or merge
/// into a folder) — `NSDraggingDestination` on AppKit isn't a protocol to
/// declare conformance to, just a family of `NSView` methods to override,
/// so both roles live on this one class.
final class LaunchpadCellView: NSView, NSDraggingSource {
    var itemID: String?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    /// Read once, right as a drag begins, for the image AppKit shows
    /// following the cursor for the rest of the session.
    var dragImageProvider: (() -> NSImage?)?
    /// Fired the instant a real drag starts (movement past the threshold) —
    /// before the native session begins, so the caller can mark this item
    /// "being dragged" (hide it, tint it) right away.
    var onDragWillBegin: (() -> Void)?
    /// Fired unconditionally when the native session ends, however it
    /// ended — dropped on a target, dropped on nothing at all, or
    /// cancelled. Unlike SwiftUI's own `.onDrag`, AppKit guarantees this
    /// callback fires, so drag state can never get stuck "in progress"
    /// forever just because the drop landed somewhere with no destination.
    var onDragEnded: (() -> Void)?

    /// This cell as a *destination*: called continuously while another
    /// item's drag hovers over it, with the drag's point (and this cell's
    /// own real, current size) so the caller can tell "near the center"
    /// (merge) from "reorder before/after" apart — with no shared
    /// frame-tracking state anywhere, since every cell always knows its own
    /// actual `bounds` directly.
    var onDropUpdate: ((CGPoint, CGSize) -> Void)?
    var onDropExit: (() -> Void)?
    var onPerformDrop: ((CGPoint, CGSize) -> Void)?

    private var pendingLongPress: DispatchWorkItem?
    private var startLocation: NSPoint = .zero
    private var isDraggingSelf = false

    private static let minimumDuration: TimeInterval = 0.45
    private static let maximumDistance: CGFloat = 50
    private static let dragStartThreshold: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startLocation = event.locationInWindow
        isDraggingSelf = false
        pendingLongPress?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingLongPress = nil
            self?.onLongPress?()
        }
        pendingLongPress = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minimumDuration, execute: workItem)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingSelf else { return }
        let distance = hypot(event.locationInWindow.x - startLocation.x, event.locationInWindow.y - startLocation.y)
        if distance > Self.dragStartThreshold, itemID != nil {
            pendingLongPress?.cancel()
            pendingLongPress = nil
            beginDrag(with: event)
            return
        }
        if pendingLongPress != nil, distance > Self.maximumDistance {
            pendingLongPress?.cancel()
            pendingLongPress = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isDraggingSelf else { return }
        guard let pendingLongPress, !pendingLongPress.isCancelled else { return }
        pendingLongPress.cancel()
        self.pendingLongPress = nil
        onTap?()
    }

    private func beginDrag(with event: NSEvent) {
        guard let itemID else { return }
        isDraggingSelf = true
        onDragWillBegin?()

        let squareSize = min(bounds.width, bounds.height)
        let imageFrame = NSRect(
            x: (bounds.width - squareSize) / 2,
            y: (bounds.height - squareSize) / 2,
            width: squareSize,
            height: squareSize
        )
        let image = dragImageProvider?() ?? NSImage(size: imageFrame.size)
        let draggingItem = NSDraggingItem(pasteboardWriter: itemID as NSString)
        draggingItem.setDraggingFrame(imageFrame, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingSelf = false
        onDragEnded?()
    }

    // MARK: - NSDraggingDestination (this cell as a drop target)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropUpdate?(convert(sender.draggingLocation, from: nil), bounds.size)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropUpdate?(convert(sender.draggingLocation, from: nil), bounds.size)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformDrop?(convert(sender.draggingLocation, from: nil), bounds.size)
        return true
    }
}

private struct LaunchpadCellRepresentable: NSViewRepresentable {
    let itemID: String
    let onTap: () -> Void
    let onLongPress: () -> Void
    let dragImageProvider: () -> NSImage?
    let onDragWillBegin: () -> Void
    let onDragEnded: () -> Void
    let onDropUpdate: (CGPoint, CGSize) -> Void
    let onDropExit: () -> Void
    let onPerformDrop: (CGPoint, CGSize) -> Void

    func makeNSView(context: Context) -> LaunchpadCellView {
        let view = LaunchpadCellView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: LaunchpadCellView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: LaunchpadCellView) {
        view.itemID = itemID
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.dragImageProvider = dragImageProvider
        view.onDragWillBegin = onDragWillBegin
        view.onDragEnded = onDragEnded
        view.onDropUpdate = onDropUpdate
        view.onDropExit = onDropExit
        view.onPerformDrop = onPerformDrop
    }
}

extension View {
    /// Overlays the raw AppKit tap/long-press/native-drag view described
    /// above on top of this cell's own SwiftUI content — last, so it sits
    /// above anything else here and actually receives clicks and drags.
    func launchpadCellGesture(
        itemID: String,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        dragImageProvider: @escaping () -> NSImage?,
        onDragWillBegin: @escaping () -> Void,
        onDragEnded: @escaping () -> Void,
        onDropUpdate: @escaping (CGPoint, CGSize) -> Void = { _, _ in },
        onDropExit: @escaping () -> Void = {},
        onPerformDrop: @escaping (CGPoint, CGSize) -> Void = { _, _ in }
    ) -> some View {
        overlay(
            LaunchpadCellRepresentable(
                itemID: itemID,
                onTap: onTap,
                onLongPress: onLongPress,
                dragImageProvider: dragImageProvider,
                onDragWillBegin: onDragWillBegin,
                onDragEnded: onDragEnded,
                onDropUpdate: onDropUpdate,
                onDropExit: onDropExit,
                onPerformDrop: onPerformDrop
            )
        )
    }
}

// MARK: - Non-cell drop zones (background, folder scrim, page-flip edges)

/// A full-bleed layer that's both a plain click target (tap to trigger,
/// e.g. "back out one level") and a drag-and-drop destination (drop to
/// trigger a *different* action, e.g. "commit whatever reorder was pending"
/// or "pull this out of its folder") — used for the Launchpad's own
/// background and the open folder's dimmed scrim, both of which already
/// needed exactly this "catch anything not claimed by more specific content
/// in front of it" role for taps before drag-and-drop needed the same
/// thing from the same layer.
final class LaunchpadScrimView: NSView {
    var onTap: (() -> Void)?
    var onDrop: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        // Swallowed deliberately: acting on `mouseUp` only (and only if it
        // lands back inside these same bounds) matches standard click
        // semantics — a press that drags off this view before releasing
        // shouldn't count as a tap on it.
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onTap?()
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?()
        return true
    }
}

private struct LaunchpadScrimRepresentable: NSViewRepresentable {
    let onTap: () -> Void
    let onDrop: () -> Void

    func makeNSView(context: Context) -> LaunchpadScrimView {
        let view = LaunchpadScrimView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: LaunchpadScrimView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: LaunchpadScrimView) {
        view.onTap = onTap
        view.onDrop = onDrop
    }
}

extension View {
    func launchpadScrim(onTap: @escaping () -> Void, onDrop: @escaping () -> Void) -> some View {
        overlay(LaunchpadScrimRepresentable(onTap: onTap, onDrop: onDrop))
    }
}

/// One of the two thin strips sitting in the grid's own outer margin —
/// nothing else is ever drawn there, so unlike the cells and scrims above
/// this never needs to worry about passing plain clicks through to
/// something behind it. Lingering a drag over one for `hoverDuration`
/// flips a page; leaving early cancels the pending flip.
final class LaunchpadEdgeZoneView: NSView {
    var onHoverStart: (() -> Void)?
    var onHoverEnd: (() -> Void)?
    var onDrop: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHoverStart?()
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverEnd?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHoverEnd?()
        onDrop?()
        return true
    }
}

private struct LaunchpadEdgeZoneRepresentable: NSViewRepresentable {
    let onHoverStart: () -> Void
    let onHoverEnd: () -> Void
    let onDrop: () -> Void

    func makeNSView(context: Context) -> LaunchpadEdgeZoneView {
        let view = LaunchpadEdgeZoneView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: LaunchpadEdgeZoneView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: LaunchpadEdgeZoneView) {
        view.onHoverStart = onHoverStart
        view.onHoverEnd = onHoverEnd
        view.onDrop = onDrop
    }
}

extension View {
    func launchpadEdgeZone(onHoverStart: @escaping () -> Void, onHoverEnd: @escaping () -> Void, onDrop: @escaping () -> Void) -> some View {
        overlay(LaunchpadEdgeZoneRepresentable(onHoverStart: onHoverStart, onHoverEnd: onHoverEnd, onDrop: onDrop))
    }
}
