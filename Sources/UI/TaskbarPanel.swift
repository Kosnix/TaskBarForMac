import AppKit
import SwiftUI

/// The floating, always-on-top panel that replaces the native Dock. It spans
/// the width of the Dock's own screen, sits just above the Dock's own
/// window level (so it visually covers the shrunken real Dock underneath —
/// see `DockController`), and follows `ThemeStore.effectivePanelHeight`.
final class TaskbarPanel: NSPanel {
    private let themeStore: ThemeStore
    private let startMenuPanel: StartMenuPanel
    private static let resizeHandleThickness: CGFloat = 5

    init(
        themeStore: ThemeStore,
        windowManager: WindowManager,
        appDiscovery: AppDiscovery,
        permissions: PermissionsManager,
        startMenuState: StartMenuState,
        onMinimizeAll: @escaping () -> Void
    ) {
        self.themeStore = themeStore
        let screenFrame = Self.frame(forHeight: themeStore.effectivePanelHeight)

        // Owns the start menu's own real window (see `StartMenuPanel`) and
        // shows/hides it whenever `startMenuState.isPresented` changes —
        // it used to be a SwiftUI `.popover` attached to the start button,
        // but a popover can't be resized by the user, which is exactly
        // what's wanted here.
        let startMenuPanel = StartMenuPanel(
            themeStore: themeStore,
            windowManager: windowManager,
            appDiscovery: appDiscovery,
            state: startMenuState
        )
        self.startMenuPanel = startMenuPanel
        startMenuState.onPresentationChange = { [weak startMenuPanel] _ in
            startMenuPanel?.syncVisibility()
        }

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = Self.aboveDockLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        let rootView = TaskbarView(
            themeStore: themeStore,
            windowManager: windowManager,
            permissions: permissions,
            onMinimizeAll: onMinimizeAll,
            startMenuState: startMenuState
        )

        let container = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        container.autoresizesSubviews = true

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        let handle = ResizeHandleView(frame: NSRect(
            x: 0,
            y: container.bounds.height - Self.resizeHandleThickness,
            width: container.bounds.width,
            height: Self.resizeHandleThickness
        ))
        handle.autoresizingMask = [.width, .minYMargin]
        handle.onDrag = { [weak themeStore] delta in
            guard let themeStore else { return }
            let current: CGFloat
            if let override = themeStore.panelHeightOverride {
                current = CGFloat(override)
            } else {
                current = themeStore.effectivePanelHeight
            }
            let newHeight = min(160, max(22, current + delta))
            themeStore.panelHeightOverride = Double(newHeight)
        }
        container.addSubview(handle)

        contentView = container

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionNow),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionNow),
            name: .panelSizeDidChange,
            object: nil
        )
    }

    func showAtDockPosition() {
        reposition()
        orderFrontRegardless()
    }

    /// Used to hide the panel while an app is fullscreen and bring it back
    /// afterwards (see `FullscreenObserver`) — `orderOut`/`orderFrontRegardless`
    /// rather than closing, so all of the panel's setup stays intact.
    func setVisible(_ visible: Bool) {
        if visible {
            reposition()
            orderFrontRegardless()
        } else {
            orderOut(nil)
            // The start menu doesn't make sense floating on its own once
            // the bar it's anchored to is gone.
            startMenuPanel.syncVisibilityAsDismissed()
        }
    }

    @objc private func repositionNow() {
        reposition()
    }

    private func reposition() {
        setFrame(Self.frame(forHeight: themeStore.effectivePanelHeight), display: true)
    }

    private static func frame(forHeight height: CGFloat) -> NSRect {
        guard let screen = DockController.dockScreen else {
            return NSRect(x: 0, y: 0, width: 1440, height: height)
        }
        return NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
    }

    /// One level above the Dock's own window level, so our panel renders on
    /// top of the (shrunken) real Dock instead of behind it.
    private static var aboveDockLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 1)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Vibrancy/glass materials (`NSVisualEffectView`, `NSGlassEffectView`)
    /// render a washed-out "inactive" look once this panel resigns key
    /// status — which happens constantly, since it's a
    /// `.nonactivatingPanel` that loses key the moment focus goes anywhere
    /// else. `NSVisualEffectView` has an explicit `.active` state to opt
    /// out of that; `NSGlassEffectView` doesn't expose an equivalent, so
    /// this overrides the property those materials actually query instead
    /// — it only affects what callers reading `isKeyWindow` observe (i.e.
    /// rendering/appearance), not the real, internally-tracked key state
    /// AppKit uses to route keyboard events, so text input (the start
    /// menu's search field) is unaffected.
    override var isKeyWindow: Bool { true }
}
