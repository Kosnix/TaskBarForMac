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
    private let barID: String

    init(windowManager: WindowManager, barID: String) {
        self.windowManager = windowManager
        self.barID = barID
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

    /// What the panel currently shows, so a poll tick that finds nothing
    /// changed only repositions it instead of rebuilding the whole view
    /// (which would also throw away the thumbnails' hover state).
    private var shownSignature = ""
    private var hoverTarget: String?
    private var hoverSince = Date()
    private var lastCapture = Date.distantPast

    /// Windows have to be hovered this long before their previews pop up,
    /// so sweeping the mouse across the bar doesn't flash one open per icon.
    private static let showDelay: TimeInterval = 0.35
    private static let captureInterval: TimeInterval = 0.9

    private func hide() {
        hoverTarget = nil
        shownSignature = ""
        orderOut(nil)
    }

    /// Shows (or updates, or hides) this panel to match whatever
    /// `windowManager.hoveredGroupID`/`groupButtonFrames` currently say —
    /// called on a short poll from `TaskbarPanel` rather than wired to a
    /// precise change notification, since `WindowManager`'s `@Observable`
    /// properties don't offer one outside of SwiftUI's own view updates.
    ///
    /// With previews on (and Screen Recording granted) every hovered app —
    /// one window or several — gets a strip of thumbnail cards; without,
    /// only a group of 2+ gets the old plain list of titles.
    func sync(tokens: ThemeTokens, panelHeight: CGFloat, previewsEnabled: Bool, screen: NSScreen?) {
        guard
            let bundleIdentifier = windowManager.hoveredGroupID,
            windowManager.activeBarID == barID,
            let buttonFrame = windowManager.groupButtonFrames[BarFrames.key(barID, bundleIdentifier)] ?? windowManager.iconFrames[BarFrames.key(barID, bundleIdentifier)],
            let screen,
            !windowManager.isEditingIcons,
            windowManager.pressedIconID == nil
        else {
            hide()
            return
        }
        let groupWindows = windowManager.windows.filter { $0.bundleIdentifier == bundleIdentifier }
        let usePreviews = previewsEnabled && WindowThumbnailStore.shared.isAuthorized
        guard !groupWindows.isEmpty, usePreviews || groupWindows.count > 1 else {
            hide()
            return
        }

        if !isVisible {
            if hoverTarget != bundleIdentifier {
                hoverTarget = bundleIdentifier
                hoverSince = Date()
            }
            guard Date().timeIntervalSince(hoverSince) >= Self.showDelay else { return }
        }
        hoverTarget = bundleIdentifier

        let signature = ([bundleIdentifier, usePreviews ? "p" : "l"] + groupWindows.map { "\($0.id)|\($0.title)|\($0.isMinimized)" }).joined(separator: "\n")
        if signature != shownSignature {
            shownSignature = signature
            let rootView: AnyView = usePreviews
                ? AnyView(WindowPreviewStrip(windows: groupWindows, tokens: tokens, windowManager: windowManager, bundleIdentifier: bundleIdentifier, thumbnails: WindowThumbnailStore.shared))
                : AnyView(GroupHoverPopoverView(windows: groupWindows, tokens: tokens, windowManager: windowManager, bundleIdentifier: bundleIdentifier))
            contentView = NSHostingView(rootView: rootView)
        }
        if usePreviews, Date().timeIntervalSince(lastCapture) >= Self.captureInterval {
            lastCapture = Date()
            WindowThumbnailStore.shared.refresh(windowIDs: groupWindows.compactMap(\.cgWindowID))
        }

        // Let SwiftUI measure its own natural size (the strip's width
        // depends on how many windows it has) before positioning.
        let fitting = (contentView as? NSHostingView<AnyView>)?.fittingSize ?? .zero

        // `buttonFrame` is in `TaskbarView`'s SwiftUI "taskbarRoot" space
        // (top-left origin, Y down, relative to the bar's own content
        // view) — converting to this screen's AppKit coordinates (bottom-
        // left origin, Y up) needs a single flip by the bar's own height,
        // then an offset by the bar's screen position.
        let buttonTopInScreen = screen.frame.minY + panelHeight - buttonFrame.minY
        let gap: CGFloat = 6
        let width = max(fitting.width, buttonFrame.width)
        // Previews center over their icon; the title list stays flush left
        // with it, as before. Either way, kept fully on screen.
        let preferredX = usePreviews ? screen.frame.minX + buttonFrame.midX - width / 2 : screen.frame.minX + buttonFrame.minX
        let x = min(max(preferredX, screen.frame.minX + 4), screen.frame.maxX - width - 4)
        setFrame(NSRect(x: x, y: buttonTopInScreen + gap, width: width, height: fitting.height), display: true)
        orderFrontRegardless()
    }

    private static var aboveTaskbarLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 2)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
