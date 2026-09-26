import AppKit
import SwiftUI

/// The grouped task button's hover window-list, as its own real floating
/// window — same reasoning as `StartMenuPanel`: `TaskbarPanel` itself is
/// exactly the bar's own height, so nothing inside it can visually extend
/// *above* the bar no matter how it's positioned in SwiftUI (the window
/// server clips to the window's own bounds regardless of what SwiftUI
/// thinks its layout looks like) — and a plain SwiftUI `.popover` doesn't
/// reliably anchor to its own source view in this app's kind of panel
/// (non-activating, unusual window level) either, which is what caused it
/// to render stretched across the whole bar instead. A tiny, separate,
/// taller window sidesteps both problems.
final class GroupHoverPanel: NSPanel {
    private let windowManager: WindowManager

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = Self.aboveTaskbarLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
    }

    /// Shows (or updates, or hides) this panel to match whatever
    /// `windowManager.hoveredGroupID`/`groupButtonFrames` currently say —
    /// called on a short poll from `TaskbarPanel` rather than wired to a
    /// precise change notification, since `WindowManager`'s `@Observable`
    /// properties don't offer one outside of SwiftUI's own view updates.
    func sync(tokens: ThemeTokens, panelHeight: CGFloat) {
        guard
            let bundleIdentifier = windowManager.hoveredGroupID,
            let buttonFrame = windowManager.groupButtonFrames[bundleIdentifier],
            let screen = DockController.dockScreen
        else {
            orderOut(nil)
            return
        }
        let groupWindows = windowManager.windows.filter { $0.bundleIdentifier == bundleIdentifier }
        guard !groupWindows.isEmpty else {
            orderOut(nil)
            return
        }

        let rootView = GroupHoverPopoverView(windows: groupWindows, tokens: tokens, windowManager: windowManager, bundleIdentifier: bundleIdentifier)
        let hostingView = NSHostingView(rootView: rootView)
        // Let SwiftUI measure its own natural size (the list's height
        // depends on how many windows it has) before positioning, rather
        // than guessing a fixed size ahead of time.
        let fitting = hostingView.fittingSize
        contentView = hostingView

        // `buttonFrame` is in `TaskbarView`'s SwiftUI "taskbarRoot" space
        // (top-left origin, Y down, relative to the bar's own content
        // view) — converting to this screen's AppKit coordinates (bottom-
        // left origin, Y up) needs a single flip by the bar's own height,
        // then an offset by the bar's screen position.
        let buttonTopInScreen = screen.frame.minY + panelHeight - buttonFrame.minY
        let gap: CGFloat = 6
        let frame = NSRect(
            x: screen.frame.minX + buttonFrame.minX,
            y: buttonTopInScreen + gap,
            width: max(fitting.width, buttonFrame.width),
            height: fitting.height
        )
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    private static var aboveTaskbarLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 2)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
