import AppKit
import SwiftUI

/// Plain AppKit mouse tracking (not SwiftUI gestures) for a taskbar icon's
/// whole interaction — tap, press-and-hold, and (once editing) drag-to-reorder
/// — all handled here directly instead of layering SwiftUI's own gesture
/// recognizers and `.draggable`/`.onDrop` on top of each other. Earlier
/// attempts tried:
/// - `.onTapGesture` + `.simultaneousGesture(LongPressGesture(...))`: every
///   ordinary click also completed as a long-press, locking every icon into
///   edit mode on the first tap.
/// - a single `.onLongPressGesture(minimumDuration:perform:onPressingChanged:)`:
///   didn't reliably deliver its "pressing ended" callback for a genuine
///   quick click on macOS, so ordinary clicks silently did nothing.
/// - this view handling tap/long-press alone, with `.draggable` from
///   `taskReorderable` still doing the actual reordering: once a `mouseDown`
///   lands on an `NSView`, that view owns the entire mouse-down…mouse-up
///   sequence — there's no way to hand a still-active sequence off to a
///   *different* view's gesture recognizer partway through, which is
///   exactly what letting `.draggable` take over mid-drag would need.
/// Doing the drag-target detection here too (comparing the live drag point
/// against `WindowManager.iconFrames`, simple geometric containment)
/// sidesteps that entirely: one view owns the whole gesture, start to
/// finish, same as `ResizeHandleView`/`ClickableMenuView`/`AutoFocusTextField`
/// already do for their own reliability needs.
private final class PressAndHoldView: NSView {
    weak var windowManager: WindowManager?
    var bundleIdentifier: String?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    /// A `DispatchWorkItem` on the main queue, not an `NSTimer`/`RunLoop`
    /// timer — while a mouse button is held down, AppKit can service the
    /// run loop in `.eventTracking` mode, which a plain `Timer` scheduled
    /// in the default mode won't fire in until the tracking session ends
    /// (i.e., not until release), which is exactly backwards from what a
    /// long-press needs. `DispatchQueue.main.asyncAfter` isn't tied to the
    /// run loop's current mode the same way and fires on schedule
    /// regardless.
    private var pendingLongPress: DispatchWorkItem?
    private var startLocation: NSPoint = .zero
    private var lastReorderTarget: String?
    private var isDraggingToReorder = false

    private static let minimumDuration: TimeInterval = 0.45
    private static let maximumDistance: CGFloat = 50
    private static let dragStartThreshold: CGFloat = 8

    /// Only actually claims left-button events — a right-click passes
    /// straight through to whatever SwiftUI content this overlay sits on
    /// top of, so `.contextMenu` there keeps responding to right-clicks
    /// exactly as if this view weren't here at all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        startLocation = event.locationInWindow
        lastReorderTarget = nil
        isDraggingToReorder = false
        pendingLongPress?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingLongPress = nil
            self?.onLongPress?()
        }
        pendingLongPress = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minimumDuration, execute: workItem)
    }

    override func mouseDragged(with event: NSEvent) {
        let distance = hypot(event.locationInWindow.x - startLocation.x, event.locationInWindow.y - startLocation.y)

        if windowManager?.isEditingIcons == true, let bundleIdentifier, distance > Self.dragStartThreshold {
            pendingLongPress?.cancel()
            pendingLongPress = nil
            isDraggingToReorder = true
            reorderIfNeeded(at: event.locationInWindow, draggedBundleIdentifier: bundleIdentifier)
            return
        }

        if pendingLongPress != nil, distance > Self.maximumDistance {
            pendingLongPress?.cancel()
            pendingLongPress = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            lastReorderTarget = nil
            isDraggingToReorder = false
        }
        // A completed reorder drag, or a long-press that already fired,
        // shouldn't *also* register as a tap on release.
        guard !isDraggingToReorder, let pendingLongPress, !pendingLongPress.isCancelled else { return }
        pendingLongPress.cancel()
        self.pendingLongPress = nil
        onTap?()
    }

    /// `event.locationInWindow` is AppKit's bottom-left-origin, Y-up window
    /// space; `WindowManager.iconFrames` was captured in SwiftUI's
    /// top-left-origin, Y-down `"taskbarRoot"` space (see `TaskbarView`) —
    /// flipping Y by the window's own content height converts between the
    /// two, the same trick `StartMenuState`'s outside-click detection
    /// already uses for the same reason.
    private func reorderIfNeeded(at locationInWindow: NSPoint, draggedBundleIdentifier: String) {
        guard let windowManager, let contentHeight = window?.contentView?.bounds.height else { return }
        let point = CGPoint(x: locationInWindow.x, y: contentHeight - locationInWindow.y)
        guard let target = windowManager.iconFrames.first(where: { $0.key != draggedBundleIdentifier && $0.value.contains(point) })?.key,
              target != lastReorderTarget else { return }
        lastReorderTarget = target
        windowManager.reorder(draggedBundleIdentifier: draggedBundleIdentifier, droppedOnBundleIdentifier: target)
    }
}

private struct PressAndHoldOverlay: NSViewRepresentable {
    let windowManager: WindowManager
    let bundleIdentifier: String?
    let onTap: () -> Void
    let onLongPress: () -> Void

    func makeNSView(context: Context) -> PressAndHoldView {
        let view = PressAndHoldView()
        view.windowManager = windowManager
        view.bundleIdentifier = bundleIdentifier
        view.onTap = onTap
        view.onLongPress = onLongPress
        return view
    }

    func updateNSView(_ nsView: PressAndHoldView, context: Context) {
        nsView.windowManager = windowManager
        nsView.bundleIdentifier = bundleIdentifier
        nsView.onTap = onTap
        nsView.onLongPress = onLongPress
    }
}

extension View {
    /// A short tap does `onTap` normally, or opens the icon picker instead
    /// if `WindowManager.isEditingIcons` is already on; holding past 0.45s
    /// enters that edit mode; dragging while already editing reorders
    /// (see `PressAndHoldView`). Also reports this icon's own frame into
    /// `WindowManager.iconFrames` (see `reportsIconFrame`), so every other
    /// icon's own drag can find it as a possible target.
    func iconPressAndHold(windowManager: WindowManager, bundleIdentifier: String?, onTap: @escaping () -> Void) -> some View {
        self
            .reportsIconFrame(bundleIdentifier: bundleIdentifier, windowManager: windowManager)
            .overlay(
                PressAndHoldOverlay(
                    windowManager: windowManager,
                    bundleIdentifier: bundleIdentifier,
                    onTap: {
                        if windowManager.isEditingIcons {
                            windowManager.presentIconPicker(for: bundleIdentifier)
                        } else {
                            onTap()
                        }
                    },
                    onLongPress: {
                        windowManager.isEditingIcons = true
                    }
                )
            )
    }

    /// Publishes this icon's own frame into `WindowManager.iconFrames`, in
    /// `TaskbarView`'s shared `"taskbarRoot"` coordinate space — the same
    /// `GeometryReader`-in-background technique `GroupedTaskButtonView`
    /// already uses for `groupButtonFrames`, just covering every icon
    /// instead of only grouped ones.
    func reportsIconFrame(bundleIdentifier: String?, windowManager: WindowManager) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        guard let bundleIdentifier else { return }
                        windowManager.iconFrames[bundleIdentifier] = geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace))
                    }
                    .onChange(of: geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace))) { _, newValue in
                        guard let bundleIdentifier else { return }
                        windowManager.iconFrames[bundleIdentifier] = newValue
                    }
            }
        )
    }
}
