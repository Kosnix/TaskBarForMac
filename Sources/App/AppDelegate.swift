import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dockController = DockController()
    private let permissions = PermissionsManager()
    private let themeStore = ThemeStore()
    private let windowManager = WindowManager()
    private let appDiscovery = AppDiscovery()
    private let startMenuState = StartMenuState()
    private lazy var shortcutsManager = ShortcutsManager(windowManager: windowManager)
    private let fullscreenObserver = FullscreenObserver()

    private var panel: TaskbarPanel?
    private var dockHeightPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        dockController.offerRecoveryIfNeeded()

        if !permissions.isTrusted {
            permissions.requestAccess()
        }

        appDiscovery.loadInBackground()
        windowManager.startAutoRefresh()

        dockController.hideDock()
        themeStore.setMinimumPanelHeight(DockController.currentReservedHeight())
        startPollingDockHeight()

        let panel = TaskbarPanel(
            themeStore: themeStore,
            windowManager: windowManager,
            appDiscovery: appDiscovery,
            permissions: permissions,
            startMenuState: startMenuState,
            onMinimizeAll: { [weak windowManager] in
                windowManager?.minimizeAll()
            }
        )
        panel.showAtDockPosition()
        self.panel = panel

        shortcutsManager.start { [weak startMenuState] in
            startMenuState?.isPresented.toggle()
        }

        fullscreenObserver.start { [weak self] isFullscreen in
            self?.panel?.setVisible(!isFullscreen)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager.stopAutoRefresh()
        dockHeightPollTimer?.invalidate()
        fullscreenObserver.stop()
        dockController.restoreDock()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The real Dock relaunches asynchronously after `hideDock()` — first
    /// the `killall`'d process has to actually restart, then *it* animates
    /// into `autohide`, so `visibleFrame` still reports the Dock's old,
    /// full (pre-hide) size for a bit. A "3 consecutive matching readings"
    /// stability check used to stop this poll early, which was exactly
    /// wrong here: those 3 readings could easily land entirely *within*
    /// that "still visible, hasn't started hiding yet" window, locking
    /// `minimumPanelHeight` onto the Dock's normal size — a giant taskbar
    /// that never corrected itself, since the timer had already stopped by
    /// the time the Dock actually finished hiding. Polling for a fixed,
    /// generous window instead — still updating the floor on every tick —
    /// means the bar visibly shrinks down as soon as the real Dock
    /// finishes hiding, whenever that actually happens, rather than
    /// gambling on an early exit.
    private func startPollingDockHeight() {
        var tickCount = 0

        dockHeightPollTimer?.invalidate()
        dockHeightPollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            tickCount += 1
            self?.themeStore.setMinimumPanelHeight(DockController.currentReservedHeight())
            if tickCount >= 20 {
                timer.invalidate()
            }
        }
    }
}
