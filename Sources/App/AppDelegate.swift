import AppKit

@MainActor
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
    /// One extra bar per additional screen (when "a bar on every screen" is
    /// on), by display id.
    private var secondaryPanels: [CGDirectDisplayID: TaskbarPanel] = [:]
    private lazy var altTab = AltTabController(windowManager: windowManager, themeStore: themeStore)
    private lazy var windowSnap = WindowSnapController(themeStore: themeStore)
    private var spaceReclaimTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        dockController.offerRecoveryIfNeeded()

        if !permissions.isTrusted {
            permissions.requestAccess()
        }

        if themeStore.windowPreviewsEnabled {
            WindowThumbnailStore.shared.requestAccessIfNeeded()
        }

        AppStatusStore.shared.startPolling()

        appDiscovery.loadInBackground()
        windowManager.startAutoRefresh()

        dockController.reserveDockSpace()
        startReclaimingReservedSpace()

        let panel = makePanel(displayID: nil)
        panel.showAtDockPosition()
        self.panel = panel

        shortcutsManager.start { [weak startMenuState, weak themeStore] in
            guard let style = themeStore?.startMenuStyle else { return }
            // Opens on the screen the pointer is on.
            let mouse = NSEvent.mouseLocation
            startMenuState?.toggleOrHandOff(style: style, screen: NSScreen.screens.first { $0.frame.contains(mouse) })
        }

        fullscreenObserver.start { [weak self] isFullscreen in
            guard let self else { return }
            self.panel?.setVisible(!isFullscreen)
            self.secondaryPanels.values.forEach { $0.setVisible(!isFullscreen) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncBars() }
        }

        NotificationCenter.default.addObserver(forName: .featuresDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFeatures() }
        }
        syncFeatures()
    }

    private func makePanel(displayID: CGDirectDisplayID?) -> TaskbarPanel {
        TaskbarPanel(
            themeStore: themeStore,
            windowManager: windowManager,
            appDiscovery: appDiscovery,
            permissions: permissions,
            startMenuState: startMenuState,
            displayID: displayID,
            onMinimizeAll: { [weak windowManager] in
                windowManager?.toggleMinimizeAll()
            }
        )
    }

    /// Opens or closes a bar for each extra screen so they match the
    /// screens that exist and the setting.
    @MainActor
    private func syncBars() {
        let wanted: Set<CGDirectDisplayID> = themeStore.barOnAllScreensEnabled
            ? Set(NSScreen.screens.dropFirst().compactMap(\.displayID))
            : []
        for (id, bar) in secondaryPanels where !wanted.contains(id) {
            bar.orderOut(nil)
            secondaryPanels[id] = nil
        }
        for id in wanted where secondaryPanels[id] == nil {
            let bar = makePanel(displayID: id)
            bar.showAtDockPosition()
            secondaryPanels[id] = bar
        }
    }

    /// Starts or stops the optional, event-driven features to match their
    /// settings.
    @MainActor
    private func syncFeatures() {
        syncBars()
        if themeStore.altTabEnabled { altTab.start() } else { altTab.stop() }
        if themeStore.windowSnapEnabled { windowSnap.start() } else { windowSnap.stop() }
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
            let barScreens = [DockController.dockScreen].compactMap { $0 } + self.secondaryPanels.keys.compactMap { id in NSScreen.screens.first { $0.displayID == id } }
            self.windowManager.reclaimReservedSpace(panelHeight: self.themeStore.effectivePanelHeight, screens: barScreens)
        }
    }
}
