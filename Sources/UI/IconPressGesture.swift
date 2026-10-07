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
/// finish, same as `CornerResizeHandleView`/`ClickableMenuView`/`AutoFocusTextField`
/// already do for their own reliability needs.
private final class PressAndHoldView: NSView {
    weak var windowManager: WindowManager?
    var bundleIdentifier: String?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    /// A press of the middle mouse button (a wheel click).
    var onMiddleClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// True from `mouseDown` until release, or until the cursor slides off
    /// the icon, or the hold turns into edit mode.
    var onPressChange: ((Bool) -> Void)?
    /// Set for a not-yet-running pinned launcher, which has nothing at all
    /// to show on right-click outside edit mode (see `hitTest`'s doc
    /// comment for why that needs handling here, not just by leaving its
    /// own `.contextMenu` unattached).
    var blocksContextMenuWhenNotEditing = false

    private var trackingArea: NSTrackingArea?

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
    private var isDraggingToReorder = false
    /// A frozen copy of `WindowManager.iconFrames`, taken once at
    /// `mouseDown` — see `reorderIfNeeded`'s doc comment for why hit-testing
    /// against a live, still-animating layout instead of this snapshot
    /// caused a real duplication bug.
    private var dragOriginalFrames: [String: CGRect] = [:]

    private static let minimumDuration: TimeInterval = 0.45
    private static let maximumDistance: CGFloat = 50
    private static let dragStartThreshold: CGFloat = 8

    /// Without this, `NSView`'s default (`false`) means the very first
    /// click on an icon while some other app is frontmost only brings this
    /// panel's window forward — it doesn't actually reach `mouseDown` at
    /// all, so the click seems to do nothing and a second click is needed
    /// to really launch/activate anything. The real Dock (and every other
    /// always-on-top utility bar) responds to the first click regardless
    /// of focus; this makes ours do the same.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only actually claims left-button events — a right-click passes
    /// straight through to whatever SwiftUI content this overlay sits on
    /// top of, so `.contextMenu` there keeps responding to right-clicks
    /// exactly as if this view weren't here at all.
    ///
    /// `LauncherButtonView` (a pinned app that isn't running) only attaches
    /// its own `.contextMenu` while editing — deliberately, since it has
    /// nothing to offer otherwise (see its own doc comment) — but a
    /// right-click this view lets pass through still doesn't just vanish:
    /// with no SwiftUI content underneath claiming it, AppKit hands it to
    /// whatever's *behind* this whole panel's content next, which turned
    /// out to be `TaskbarContainerView`'s own right-click handler — showing
    /// the bar's personalization menu over a closed app icon instead of no
    /// menu at all. `blocksContextMenuWhenNotEditing` claims the right-click
    /// itself in exactly that situation (see `rightMouseDown`, which then
    /// does nothing with it) so it stops there instead of falling through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseDown, .otherMouseUp:
            return super.hitTest(point)
        case .rightMouseDown where blocksContextMenuWhenNotEditing && windowManager?.isEditingIcons != true:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    /// Only ever reached when `hitTest` just claimed a right-click for the
    /// "nothing to show" case above — intentionally empty, not forwarded to
    /// `super`, so the click simply stops here instead of reaching
    /// anything else (a menu, or the bar's own right-click handler) at all.
    override func rightMouseDown(with event: NSEvent) {}

    /// Hover state comes from here — a plain `NSTrackingArea`, not
    /// SwiftUI's own `.onHover` — because `.onHover` attached in the same
    /// view subtree as `.hoverLift`'s animated scale/shadow turned out to
    /// flicker: the hover-driven re-render appears to tear down and
    /// recreate SwiftUI's own tracking area mid-animation, and re-adding a
    /// tracking area while the cursor already sits inside its rect makes
    /// AppKit fire a spurious exit-then-re-enter pair, which restarts the
    /// animation, which repeats it — a real, if short-lived, feedback
    /// loop. This view's own identity is stable across those re-renders
    /// (SwiftUI only calls `updateNSView`, never recreates it), so its
    /// tracking area is never torn down for that reason.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPressChange?(true)
        startLocation = event.locationInWindow
        isDraggingToReorder = false
        // Only this bar's own icons — every bar reports its frames under
        // its own prefix (see `BarFrames`).
        let prefix = BarFrames.key((window as? TaskbarPanel)?.barID ?? "", "")
        dragOriginalFrames = Dictionary(uniqueKeysWithValues: (windowManager?.iconFrames ?? [:]).compactMap { key, frame in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), frame) : nil
        })
        pendingLongPress?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingLongPress = nil
            self?.onPressChange?(false)
            self?.onLongPress?()
        }
        pendingLongPress = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minimumDuration, execute: workItem)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        onPressChange?(true)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        onPressChange?(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onMiddleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onPressChange?(bounds.contains(convert(event.locationInWindow, from: nil)))
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
        onPressChange?(false)
        defer { isDraggingToReorder = false }
        // A completed reorder drag, or a long-press that already fired,
        // shouldn't *also* register as a tap on release.
        guard !isDraggingToReorder, let pendingLongPress, !pendingLongPress.isCancelled else { return }
        pendingLongPress.cancel()
        self.pendingLongPress = nil
        onTap?()
    }

    /// A drop point that isn't over *any* icon still needs to resolve to the
    /// nearest one — see `verticalTolerance`'s doc comment just below.
    private static let verticalTolerance: CGFloat = 12

    /// `event.locationInWindow` is AppKit's bottom-left-origin, Y-up window
    /// space; `WindowManager.iconFrames` was captured in SwiftUI's
    /// top-left-origin, Y-down `"taskbarRoot"` space (see `TaskbarView`) —
    /// flipping Y by the window's own content height converts between the
    /// two, the same trick `StartMenuState`'s outside-click detection
    /// already uses for the same reason.
    ///
    /// Picks the closest icon by horizontal center, not the one whose own
    /// frame strictly contains the point — each icon's reported frame is
    /// only as wide as the icon itself, not the `effectiveTaskbarIconSpacing`
    /// gap the HStack adds *between* icons, so a drop point landing in that
    /// gap (easy to do between two icons sitting right next to each other)
    /// used to match nothing and silently fail to reorder — exactly the
    /// "can't insert between these two, have to jump past to the next one"
    /// bug this replaces. `verticalTolerance` is similarly forgiving of the
    /// cursor drifting slightly above/below the row mid-drag.
    ///
    /// Hit-tests against `dragOriginalFrames` (frozen at `mouseDown`), not
    /// the live `WindowManager.iconFrames` — every reorder shuffles icons
    /// into new positions with a 0.35s spring animation, and `iconFrames`
    /// only catches up to those positions as SwiftUI actually re-renders
    /// each frame of it. Reading the live dictionary meant a drag that kept
    /// re-evaluating its target every tick (needed for reversing a drag —
    /// see `WindowManager.reorder`'s own no-op guard) could pick a target
    /// based on stale, still-mid-flight coordinates, re-trigger another
    /// reorder before the first had settled, and thrash: two rapid,
    /// conflicting reorders landing faster than SwiftUI could animate
    /// between them left two icons' views visually overlapping in the same
    /// spot. The original layout's slot positions don't actually move
    /// (only which icon occupies which slot does), so freezing them for the
    /// whole gesture and only ever comparing the live cursor point against
    /// that fixed snapshot removes the race entirely.
    private func reorderIfNeeded(at locationInWindow: NSPoint, draggedBundleIdentifier: String) {
        guard let windowManager, let contentHeight = window?.contentView?.bounds.height else { return }
        let point = CGPoint(x: locationInWindow.x, y: contentHeight - locationInWindow.y)
        let candidates = dragOriginalFrames.filter {
            $0.key != draggedBundleIdentifier
                && point.y >= $0.value.minY - Self.verticalTolerance
                && point.y <= $0.value.maxY + Self.verticalTolerance
        }
        guard let targetEntry = candidates.min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }) else { return }
        // No "already tried this target" guard here any more — `WindowManager.reorder`
        // itself now bails out when the resulting order wouldn't actually
        // change, which is what lets passing over an icon, continuing past
        // it, and coming straight back to that same icon trigger a second,
        // different reorder instead of silently doing nothing.
        //
        // Which side to land on comes from the cursor's own position
        // relative to the target's (frozen) midpoint — not from comparing
        // indices, which flips every time this fires against the *same*
        // static target and used to oscillate forever (see
        // `WindowManager.reorder`'s doc comment). A fixed cursor position
        // always reads the same side, so repeat calls settle instead of
        // fighting each other.
        let insertBefore = point.x < targetEntry.value.midX
        windowManager.reorder(draggedBundleIdentifier: draggedBundleIdentifier, droppedOnBundleIdentifier: targetEntry.key, insertBefore: insertBefore)
    }
}

private struct PressAndHoldOverlay: NSViewRepresentable {
    let windowManager: WindowManager
    let bundleIdentifier: String?
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onHoverChange: (Bool) -> Void
    let onPressChange: (Bool) -> Void
    let onMiddleClick: (() -> Void)?
    var blocksContextMenuWhenNotEditing = false

    func makeNSView(context: Context) -> PressAndHoldView {
        let view = PressAndHoldView()
        view.windowManager = windowManager
        view.bundleIdentifier = bundleIdentifier
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.onHoverChange = onHoverChange
        view.onPressChange = onPressChange
        view.onMiddleClick = onMiddleClick
        view.blocksContextMenuWhenNotEditing = blocksContextMenuWhenNotEditing
        return view
    }

    func updateNSView(_ nsView: PressAndHoldView, context: Context) {
        nsView.windowManager = windowManager
        nsView.bundleIdentifier = bundleIdentifier
        nsView.onTap = onTap
        nsView.onLongPress = onLongPress
        nsView.onHoverChange = onHoverChange
        nsView.onPressChange = onPressChange
        nsView.onMiddleClick = onMiddleClick
        nsView.blocksContextMenuWhenNotEditing = blocksContextMenuWhenNotEditing
    }
}

extension View {
    /// `pressID` is what `WindowManager.pressedIconID` is set to while this
    /// icon is held down (the button view compares it to draw the pressed
    /// look). A short tap does `onTap` normally; holding past 0.45s enters edit
    /// mode; dragging while already editing reorders (see `PressAndHoldView`).
    /// A left tap does nothing while already editing — changing an icon's
    /// picture is a right-click action instead (see each button view's own
    /// `.contextMenu`), so a plain tap can't pop the file picker by
    /// accident while you're just rearranging icons. Also reports this
    /// icon's own frame into `WindowManager.iconFrames` (see
    /// `reportsIconFrame`), so every other icon's own drag can find it as a
    /// possible target.
    func iconPressAndHold(windowManager: WindowManager, bundleIdentifier: String?, pressID: String, onMiddleClick: (() -> Void)? = nil, onTap: @escaping () -> Void, blocksContextMenuWhenNotEditing: Bool = false, onHoverChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        self
            .reportsIconFrame(bundleIdentifier: bundleIdentifier, windowManager: windowManager)
            .overlay(
                PressAndHoldOverlay(
                    windowManager: windowManager,
                    bundleIdentifier: bundleIdentifier,
                    onTap: {
                        guard !windowManager.isEditingIcons else { return }
                        onTap()
                    },
                    onLongPress: {
                        windowManager.isEditingIcons = true
                    },
                    onHoverChange: onHoverChange,
                    onPressChange: { pressed in
                        if pressed {
                            windowManager.pressedIconID = pressID
                        } else if windowManager.pressedIconID == pressID {
                            windowManager.pressedIconID = nil
                        }
                    },
                    onMiddleClick: onMiddleClick.map { action in
                        { if !windowManager.isEditingIcons { action() } }
                    },
                    blocksContextMenuWhenNotEditing: blocksContextMenuWhenNotEditing
                )
            )
    }

    /// Publishes this icon's own frame into `WindowManager.iconFrames`, in
    /// `TaskbarView`'s shared `"taskbarRoot"` coordinate space — the same
    /// `GeometryReader`-in-background technique `GroupedTaskButtonView`
    /// already uses for `groupButtonFrames`, just covering every icon
    /// instead of only grouped ones.
    func reportsIconFrame(bundleIdentifier: String?, windowManager: WindowManager) -> some View {
        background(IconFrameReporter(bundleIdentifier: bundleIdentifier, windowManager: windowManager))
    }
}

/// Reads the bar it's in from the environment, which a bare `View`
/// extension can't — hence its own small view.
private struct IconFrameReporter: View {
    let bundleIdentifier: String?
    let windowManager: WindowManager
    @Environment(\.barID) private var barID

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    guard let bundleIdentifier else { return }
                    windowManager.iconFrames[BarFrames.key(barID, bundleIdentifier)] = geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace))
                }
                .onChange(of: geo.frame(in: .named(TaskbarView.taskbarRootCoordinateSpace))) { _, newValue in
                    guard let bundleIdentifier else { return }
                    windowManager.iconFrames[BarFrames.key(barID, bundleIdentifier)] = newValue
                }
        }
    }
}
