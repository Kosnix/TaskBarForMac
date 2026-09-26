import AppKit
import SwiftUI

/// The floating, always-on-top panel that replaces the native Dock. It spans
/// the width of the Dock's own screen, sits just above the Dock's own
/// window level (so it visually covers the shrunken real Dock underneath —
/// see `DockController`), and follows `ThemeStore.effectivePanelHeight`.
final class TaskbarPanel: NSPanel {
    private let themeStore: ThemeStore
    private let windowManager: WindowManager
    private let startMenuPanel: StartMenuPanel
    private let startMenuState: StartMenuState
    private let groupHoverPanel: GroupHoverPanel
    private static let resizeHandleThickness: CGFloat = 5

    // MARK: Auto-hide (Windows-style: retract off-screen except a thin
    // hover-to-reveal sliver when the mouse isn't near it)
    private static let autoHideRevealSliver: CGFloat = 3
    private static let autoHideRetractDelay: TimeInterval = 0.6
    private var autoHideTimer: Timer?
    private var isRetracted = false
    private var retractWorkItem: DispatchWorkItem?

    init(
        themeStore: ThemeStore,
        windowManager: WindowManager,
        appDiscovery: AppDiscovery,
        permissions: PermissionsManager,
        startMenuState: StartMenuState,
        onMinimizeAll: @escaping () -> Void
    ) {
        self.themeStore = themeStore
        self.windowManager = windowManager
        self.startMenuState = startMenuState
        self.groupHoverPanel = GroupHoverPanel(windowManager: windowManager)
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

        let container = TaskbarContainerView(frame: NSRect(origin: .zero, size: screenFrame.size))
        container.autoresizesSubviews = true
        container.themeStore = themeStore
        container.windowManager = windowManager

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

        startAutoHideTracking()
    }

    deinit {
        autoHideTimer?.invalidate()
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
            // the bar it's anchored to is gone — same for the group-hover
            // popup, which anchors to a button on the (now gone) bar.
            startMenuPanel.syncVisibilityAsDismissed()
            groupHoverPanel.orderOut(nil)
        }
    }

    @objc private func repositionNow() {
        reposition()
    }

    private func reposition() {
        setFrame(isRetracted ? retractedFrame() : Self.frame(forHeight: themeStore.effectivePanelHeight), display: true)
    }

    private func syncGroupHoverPanel() {
        guard var tokens = themeStore.activeTheme?.tokens else { return }
        tokens.panel.height = themeStore.effectivePanelHeight
        groupHoverPanel.sync(tokens: tokens, panelHeight: tokens.panel.height)
    }

    // MARK: - Auto-hide

    private func startAutoHideTracking() {
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.checkAutoHide()
        }
    }

    private func checkAutoHide() {
        // Piggybacks on this same 0.15s tick rather than a second timer —
        // `WindowManager`'s `@Observable` properties don't offer a plain
        // change callback outside of SwiftUI's own view updates, so this
        // panel's visibility/position is kept in sync by polling instead.
        syncGroupHoverPanel()

        guard themeStore.autoHideEnabled else {
            retractWorkItem?.cancel()
            retractWorkItem = nil
            if isRetracted { reveal() }
            return
        }
        guard let screen = DockController.dockScreen else { return }
        let mouse = NSEvent.mouseLocation
        // The "hot edge": the very bottom row of pixels on the bar's own
        // screen, the same trigger Windows' own auto-hidden taskbar uses.
        let atHotEdge = mouse.y <= screen.frame.minY + 2 && mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
        let overBar = frame.contains(mouse)
        // Never retract out from under an open start menu or a live drag
        // (spring-loading, reordering) — both would be left stranded.
        if atHotEdge || overBar || startMenuState.isPresented {
            retractWorkItem?.cancel()
            retractWorkItem = nil
            if isRetracted { reveal() }
        } else if !isRetracted && retractWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.retract()
                self?.retractWorkItem = nil
            }
            retractWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideRetractDelay, execute: work)
        }
    }

    private func retract() {
        guard !isRetracted, themeStore.autoHideEnabled else { return }
        isRetracted = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            self.animator().setFrame(self.retractedFrame(), display: true)
        }
    }

    private func reveal() {
        isRetracted = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            self.animator().setFrame(Self.frame(forHeight: self.themeStore.effectivePanelHeight), display: true)
        }
    }

    /// The bar's frame when retracted: shifted down so only a thin sliver
    /// peeks above the screen's bottom edge — that sliver, and the hot
    /// edge itself, are what a hover reveals it again from.
    private func retractedFrame() -> NSRect {
        var retracted = Self.frame(forHeight: themeStore.effectivePanelHeight)
        retracted.origin.y -= (retracted.height - Self.autoHideRevealSliver)
        return retracted
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
