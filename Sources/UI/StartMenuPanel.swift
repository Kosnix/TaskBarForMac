import AppKit
import SwiftUI

/// The Kickoff-style start menu, as a real (resizable) floating window
/// instead of a SwiftUI `.popover` — a popover has no built-in way to be
/// dragged bigger by the user, which is exactly what's wanted here (see
/// `ThemeStore.startMenuSizeOverride`). Anchored just above the start
/// button, flush with the screen's left edge, and grows up/right from
/// there via the corner handle.
final class StartMenuPanel: NSPanel {
    private let themeStore: ThemeStore
    private let windowManager: WindowManager
    private let appDiscovery: AppDiscovery
    private let state: StartMenuState
    private static let resizeHandleSize: CGFloat = 16
    private weak var resizeHandle: CornerResizeHandleView?

    init(
        themeStore: ThemeStore,
        windowManager: WindowManager,
        appDiscovery: AppDiscovery,
        state: StartMenuState
    ) {
        self.themeStore = themeStore
        self.windowManager = windowManager
        self.appDiscovery = appDiscovery
        self.state = state
        let initialFrame = Self.frame(themeStore: themeStore, screen: nil)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = Self.aboveTaskbarLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: initialFrame.size))
        container.autoresizesSubviews = true

        let hostingView = NSHostingView(rootView: makeRootView())
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        let handle = CornerResizeHandleView(frame: NSRect(
            x: container.bounds.width - Self.resizeHandleSize,
            y: container.bounds.height - Self.resizeHandleSize,
            width: Self.resizeHandleSize,
            height: Self.resizeHandleSize
        ))
        handle.autoresizingMask = [.minXMargin, .minYMargin]
        handle.onDrag = { [weak themeStore] dWidth, dHeight in
            guard let themeStore else { return }
            let current = themeStore.effectiveStartMenuSize
            let minSize = themeStore.effectiveStartMenuMinSize
            let newSize = CGSize(
                width: min(ThemeStore.startMenuMaxSize.width, max(minSize.width, current.width + dWidth)),
                height: min(ThemeStore.startMenuMaxSize.height, max(minSize.height, current.height + dHeight))
            )
            themeStore.startMenuSizeOverride = newSize
        }
        container.addSubview(handle)
        resizeHandle = handle

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
            name: .startMenuSizeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionNow),
            name: .panelSizeDidChange,
            object: nil
        )
    }

    /// Type-erased since the actual view swaps between `StartMenuView` and
    /// `Windows11StartMenuView` depending on `ThemeStore.startMenuStyle` —
    /// `NSHostingView`'s own generic type has to be fixed to whatever this
    /// returns, so both layouts share one hosting view via `AnyView`.
    private func makeRootView() -> AnyView {
        // Same fix-up `TaskbarView.content(for:)` applies: `activeTheme`
        // on its own still carries the theme's *default* `panel.height`
        // (e.g. 36), not the user's effective one (override, or floored by
        // the Dock) — and icon sizing here is meant to track the taskbar's
        // actual height, not the theme's nominal one.
        var theme = themeStore.activeTheme ?? ThemeLoader.loadAllThemes()[0]
        theme.tokens.panel.height = themeStore.effectivePanelHeight
        theme.tokens.taskbarIconRatio = themeStore.taskbarIconRatio
        let onLaunch: () -> Void = { [weak state] in state?.isPresented = false }

        switch themeStore.startMenuStyle {
        case .kickoff, .realSpotlight, .nativeApps:
            // `.realSpotlight`/`.nativeApps` never actually present this panel (see
            // `StartMenuState.toggleOrHandOff`) — falling back to the
            // default layout here is just so this switch stays exhaustive,
            // not something that's ever visibly reachable.
            return AnyView(StartMenuView(
                appDiscovery: appDiscovery,
                windowManager: windowManager,
                theme: theme,
                state: state,
                liquidGlassEnabled: themeStore.liquidGlassEnabled,
                liquidGlassIntensity: themeStore.liquidGlassIntensity,
                infiniteScroll: themeStore.infiniteScrollEnabled,
                onLaunch: onLaunch
            ))
        case .windows11:
            return AnyView(Windows11StartMenuView(
                appDiscovery: appDiscovery,
                windowManager: windowManager,
                theme: theme,
                state: state,
                liquidGlassEnabled: themeStore.liquidGlassEnabled,
                liquidGlassIntensity: themeStore.liquidGlassIntensity,
                infiniteScroll: themeStore.infiniteScrollEnabled,
                onLaunch: onLaunch
            ))
        case .windows7:
            return AnyView(Windows7StartMenuView(
                appDiscovery: appDiscovery,
                windowManager: windowManager,
                theme: theme,
                state: state,
                liquidGlassEnabled: themeStore.liquidGlassEnabled,
                liquidGlassIntensity: themeStore.liquidGlassIntensity,
                infiniteScroll: themeStore.infiniteScrollEnabled,
                onLaunch: onLaunch
            ))
        case .launchpad:
            return AnyView(LaunchpadStartMenuView(
                appDiscovery: appDiscovery,
                windowManager: windowManager,
                theme: theme,
                state: state,
                onLaunch: onLaunch
            ))
        }
    }

    /// Shows or hides the panel to match `state.isPresented`, rebuilding
    /// its content with the latest theme/settings first — called whenever
    /// that changes (wired up from `StartMenuState.onPresentationChange` by
    /// whoever owns this panel).
    func syncVisibility() {
        guard state.isPresented else {
            orderOut(nil)
            return
        }
        // Whatever was uninstalled or trashed since the last directory
        // event (or from somewhere nothing watches) shouldn't be offered.
        appDiscovery.pruneMissingApps()
        (contentView?.subviews.first as? NSHostingView<AnyView>)?.rootView = makeRootView()
        // Resizing a full-screen menu makes no sense — the handle only
        // shows for every other, anchored-and-user-sizable style.
        resizeHandle?.isHidden = themeStore.startMenuStyle == .launchpad
        reposition()
        orderFrontRegardless()
        makeKey()
    }

    /// Called when `TaskbarPanel` itself is being hidden (fullscreen) —
    /// the menu doesn't make sense floating on its own without the bar
    /// it's anchored to, so this dismisses it the same way an outside
    /// click would (updating `state.isPresented`, not just hiding the
    /// window), in case it was open.
    func syncVisibilityAsDismissed() {
        state.isPresented = false
    }

    @objc private func repositionNow() {
        guard state.isPresented else { return }
        reposition()
    }

    private func reposition() {
        setFrame(Self.frame(themeStore: themeStore, screen: state.anchorScreen), display: true)
    }

    private static func frame(themeStore: ThemeStore, screen anchor: NSScreen?) -> NSRect {
        guard let screen = anchor ?? DockController.dockScreen else {
            return NSRect(origin: .zero, size: themeStore.effectiveStartMenuSize)
        }
        // Launchpad covers the whole screen, like the real thing — not
        // anchored above the bar or sized/resizable like every other style.
        if themeStore.startMenuStyle == .launchpad {
            return screen.frame
        }
        let size = themeStore.effectiveStartMenuSize
        let barHeight = themeStore.effectivePanelHeight
        // When the start button itself travels to the middle of the bar
        // ("Centrer avec le menu démarrer"), the menu it opens follows it
        // there instead of staying flush against the screen's left edge.
        let x = themeStore.centerTaskListEnabled && themeStore.centerIncludesStartButton
            ? screen.frame.minX + (screen.frame.width - size.width) / 2
            : screen.frame.minX
        return NSRect(x: x, y: screen.frame.minY + barHeight, width: size.width, height: size.height)
    }

    /// One level above the taskbar panel's own level, so the menu renders
    /// on top of it instead of behind it.
    private static var aboveTaskbarLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 2)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var isKeyWindow: Bool { true }
}
