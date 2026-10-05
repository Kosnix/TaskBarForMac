import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dockController = DockController()
    private let permissions = PermissionsManager()
    private let themeStore = ThemeStore()
    private let windowManager = WindowManager()
    private let appDiscovery = AppDiscovery()
    private let startMenuState = StartMenuState()
    private lazy var shortcutsManager = ShortcutsManager(windowManager: windowManager, startMenuState: startMenuState, themeStore: themeStore)
    private let fullscreenObserver = FullscreenObserver()

    private var panel: TaskbarPanel?
    private var spaceReclaimTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        dockController.offerRecoveryIfNeeded()

        if !permissions.isTrusted {
            permissions.requestAccess()
        }

        appDiscovery.loadInBackground()
        windowManager.startAutoRefresh()

        dockController.reserveDockSpace()
        startReclaimingReservedSpace()

        let panel = TaskbarPanel(
            themeStore: themeStore,
            windowManager: windowManager,
            appDiscovery: appDiscovery,
            permissions: permissions,
            startMenuState: startMenuState,
            onMinimizeAll: { [weak windowManager] in
                windowManager?.toggleMinimizeAll()
            }
        )
        panel.showAtDockPosition()
        self.panel = panel

        shortcutsManager.start { [weak startMenuState, weak themeStore] in
            guard let style = themeStore?.startMenuStyle else { return }
            startMenuState?.toggleOrHandOff(style: style)
        }

        fullscreenObserver.start { [weak self] isFullscreen in
            self?.panel?.setVisible(!isFullscreen)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager.stopAutoRefresh()
        spaceReclaimTimer?.invalidate()
        fullscreenObserver.stop()
        dockController.restoreDock()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// With the real Dock fully auto-hidden, macOS no longer reserves any
    /// space for it, so a maximized/zoomed window can size itself right
    /// under our panel — this repeatedly nudges any window that does back
    /// above it (see `WindowManager.reclaimReservedSpace`). Matches the
    /// panel's own auto-hide check's cadence (`TaskbarPanel`), fast enough
    /// that a freshly zoomed window gets corrected before it's noticeable.
    private func startReclaimingReservedSpace() {
        spaceReclaimTimer?.invalidate()
        spaceReclaimTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.windowManager.reclaimReservedSpace(panelHeight: self.themeStore.effectivePanelHeight)
        }
    }
}
