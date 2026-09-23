import Foundation
import Observation

extension Notification.Name {
    /// Posted whenever the effective panel size changes, so `TaskbarPanel`
    /// (a plain NSPanel, outside SwiftUI's own re-render cycle) knows to
    /// resize the actual window, not just the content inside it.
    static let panelSizeDidChange = Notification.Name("TB.panelSizeDidChange")

    /// Posted specifically when the *desired* height changes — the user's
    /// override, or the active theme's own default — as opposed to
    /// `effectivePanelHeight`, which also folds in the real Dock's measured
    /// reservation. `AppDelegate` listens for this one to know when to
    /// re-reserve Dock space; listening to `panelSizeDidChange` instead
    /// would create a feedback loop, since re-reserving changes the very
    /// measurement that feeds `effectivePanelHeight`'s floor.
    static let desiredPanelHeightDidChange = Notification.Name("TB.desiredPanelHeightDidChange")

    /// Posted whenever the start menu's effective size changes (a manual
    /// resize, or the taskbar's own height changing the dynamic default),
    /// so `StartMenuPanel` knows to resize the actual window.
    static let startMenuSizeDidChange = Notification.Name("TB.startMenuSizeDidChange")
}

/// Holds the active theme and every theme discovered on disk, and hot-reloads
/// the active theme's folder so editing tokens.json updates the UI live.
/// Also owns the user's panel-size override and the real Dock's measured
/// minimum height, so the two can be reconciled into one effective height.
@Observable
final class ThemeStore {
    private(set) var availableThemes: [Theme] = []
    private(set) var activeTheme: Theme?

    /// The height (in points) the real Dock still reserves at the bottom of
    /// the screen (see `DockController.replaceDock()`). The panel never
    /// renders shorter than this, so other apps' windows keep avoiding it.
    private(set) var minimumPanelHeight: CGFloat = 0

    private static let heightOverrideKey = "TB.panel.heightOverride"
    private static let activeThemeIDKey = "TB.theme.activeID"

    /// User-chosen panel height from the right-click "Taille de la barre"
    /// menu, persisted across launches. `nil` means "use the theme's own
    /// default".
    var panelHeightOverride: Double? {
        didSet {
            if let panelHeightOverride {
                UserDefaults.standard.set(panelHeightOverride, forKey: Self.heightOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.heightOverrideKey)
            }
            NotificationCenter.default.post(name: .panelSizeDidChange, object: nil)
            NotificationCenter.default.post(name: .desiredPanelHeightDidChange, object: nil)
        }
    }

    /// The height the panel *wants* to be — the user's override, or the
    /// active theme's own default — before it's floored by the real Dock's
    /// measured reservation. See `.desiredPanelHeightDidChange`.
    var desiredPanelHeight: CGFloat {
        if let panelHeightOverride {
            return CGFloat(panelHeightOverride)
        }
        return CGFloat(activeTheme?.tokens.panel.height ?? 44)
    }

    /// The real Dock's shadow/reflection renders a little beyond its own
    /// reserved `visibleFrame` inset, so matching that inset exactly still
    /// left a sliver of it peeking out; this pads our panel a bit taller so
    /// it fully covers it. Purely visual — doesn't change what space macOS
    /// reserves for other windows.
    private static let dockCoverageBuffer: CGFloat = 8

    /// What the panel should actually render at: the user's override (or
    /// the theme's default), floored by the real Dock's reserved height
    /// (plus a small buffer so it's fully covered, not just exactly reserved).
    var effectivePanelHeight: CGFloat {
        let floor = minimumPanelHeight > 0 ? minimumPanelHeight + Self.dockCoverageBuffer : 0
        return max(desiredPanelHeight, floor)
    }

    private static let taskDisplayStyleOverrideKey = "TB.taskButton.displayStyleOverride"

    /// User-chosen task-button style from the right-click menu: icon + label
    /// (the theme's usual style) or icon-only (Plasma's "Icons-only Task
    /// Manager" equivalent). `nil` means "use the theme's own default".
    var taskDisplayStyleOverride: String? {
        didSet {
            if let taskDisplayStyleOverride {
                UserDefaults.standard.set(taskDisplayStyleOverride, forKey: Self.taskDisplayStyleOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.taskDisplayStyleOverrideKey)
            }
        }
    }

    var effectiveTaskDisplayStyle: String {
        taskDisplayStyleOverride ?? activeTheme?.tokens.taskButton.displayStyle ?? "iconAndLabel"
    }

    private static let liquidGlassEnabledKey = "TB.panel.liquidGlassEnabled"

    /// Opt-in replacement for the theme's own blur/flat background with
    /// macOS's system "Liquid Glass" material (`NSGlassEffectView`, macOS
    /// 26+). Persisted, off by default since it's a system-wide look, not
    /// something every theme's design was built around.
    var liquidGlassEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liquidGlassEnabled, forKey: Self.liquidGlassEnabledKey)
        }
    }

    private static let liquidGlassIntensityKey = "TB.panel.liquidGlassIntensity"

    /// How strongly the theme's own color tints the Liquid Glass look, from
    /// 0 (as see-through as the material allows) to 1 (close to a solid,
    /// flat panel) — the slider next to the on/off toggle in the
    /// personalization menu.
    var liquidGlassIntensity: Double {
        didSet {
            UserDefaults.standard.set(liquidGlassIntensity, forKey: Self.liquidGlassIntensityKey)
        }
    }

    private static let startMenuWidthOverrideKey = "TB.startMenu.widthOverride"
    private static let startMenuHeightOverrideKey = "TB.startMenu.heightOverride"

    /// User-resized start menu dimensions (dragging its corner handle),
    /// persisted across launches. `nil` means "use the dynamic default" —
    /// see `effectiveStartMenuSize`.
    var startMenuSizeOverride: CGSize? {
        didSet {
            if let startMenuSizeOverride {
                UserDefaults.standard.set(Double(startMenuSizeOverride.width), forKey: Self.startMenuWidthOverrideKey)
                UserDefaults.standard.set(Double(startMenuSizeOverride.height), forKey: Self.startMenuHeightOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.startMenuWidthOverrideKey)
                UserDefaults.standard.removeObject(forKey: Self.startMenuHeightOverrideKey)
            }
            NotificationCenter.default.post(name: .startMenuSizeDidChange, object: nil)
        }
    }

    private static let referenceBarHeight: CGFloat = 36
    private static let startMenuBaseSize = CGSize(width: 580, height: 452)
    private static let startMenuScaleRange: ClosedRange<CGFloat> = 0.7...2.2
    static let startMenuMinSize = CGSize(width: 320, height: 260)
    static let startMenuMaxSize = CGSize(width: 1000, height: 800)

    /// The start menu's default size scales with the taskbar's own
    /// height — a taller bar (bigger icons) reads oddly next to a
    /// start menu sized for the default bar — clamped to a sane range so
    /// an extreme bar height doesn't produce an absurd menu.
    var dynamicStartMenuSize: CGSize {
        let scale = Self.startMenuScaleRange.clamp(effectivePanelHeight / Self.referenceBarHeight)
        return CGSize(width: Self.startMenuBaseSize.width * scale, height: Self.startMenuBaseSize.height * scale)
    }

    /// What the start menu should actually render at: the user's manual
    /// resize if there is one, else the dynamic default.
    var effectiveStartMenuSize: CGSize {
        startMenuSizeOverride ?? dynamicStartMenuSize
    }

    /// Mirrors `Localization.languageOverride` (the actual persisted,
    /// globally-readable value — `L(...)` is called from plenty of places
    /// that have no `ThemeStore` in reach, like `SessionManager`'s alert
    /// text) as a genuine `@Observable` *stored* property purely so
    /// SwiftUI re-renders when it changes. A computed pass-through to
    /// `Localization.languageOverride` wouldn't do that: `@Observable`
    /// only instruments real stored properties, so reading/writing through
    /// a computed one is invisible to Observation, and nothing would tell
    /// SwiftUI a re-render is needed. `TaskbarView`/`StartMenuView` read
    /// this once per render (a no-op read) specifically to establish that
    /// dependency, since none of the `L(...)` calls in their bodies touch
    /// `ThemeStore` themselves.
    var languageOverride: String? {
        didSet {
            Localization.languageOverride = languageOverride
        }
    }

    private var watchedSource: DispatchSourceFileSystemObject?
    private var watchedDescriptor: CInt = -1
    private var reloadWorkItem: DispatchWorkItem?

    init(preferredThemeID: String = "breeze-dark") {
        liquidGlassEnabled = UserDefaults.standard.bool(forKey: Self.liquidGlassEnabledKey)
        if let storedIntensity = UserDefaults.standard.object(forKey: Self.liquidGlassIntensityKey) as? Double {
            liquidGlassIntensity = storedIntensity
        } else {
            liquidGlassIntensity = 0.35
        }
        languageOverride = Localization.languageOverride
        if let storedWidth = UserDefaults.standard.object(forKey: Self.startMenuWidthOverrideKey) as? Double,
           let storedHeight = UserDefaults.standard.object(forKey: Self.startMenuHeightOverrideKey) as? Double {
            startMenuSizeOverride = CGSize(width: storedWidth, height: storedHeight)
        }
        if let stored = UserDefaults.standard.object(forKey: Self.heightOverrideKey) as? Double {
            panelHeightOverride = stored
        }
        if let stored = UserDefaults.standard.string(forKey: Self.taskDisplayStyleOverrideKey) {
            taskDisplayStyleOverride = stored
        }
        reloadThemeList()
        // The user's last pick (from the right-click theme switcher) wins
        // over the hardcoded default, so it survives a relaunch.
        let rememberedID = UserDefaults.standard.string(forKey: Self.activeThemeIDKey) ?? preferredThemeID
        if let preferred = availableThemes.first(where: { $0.id == rememberedID }) {
            setActiveTheme(preferred)
        } else if let first = availableThemes.first {
            setActiveTheme(first)
        }
    }

    /// Called once at launch with what `DockController.replaceDock()`
    /// measured.
    func setMinimumPanelHeight(_ height: CGFloat) {
        minimumPanelHeight = height
        NotificationCenter.default.post(name: .panelSizeDidChange, object: nil)
    }

    func reloadThemeList() {
        // Discovery order is filesystem order (unpredictable), not
        // alphabetical — sort by display name so the theme switcher menu
        // lists them predictably.
        availableThemes = ThemeLoader.loadAllThemes()
            .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    func setActiveTheme(_ theme: Theme) {
        activeTheme = theme
        UserDefaults.standard.set(theme.id, forKey: Self.activeThemeIDKey)
        watchActiveThemeFolder()
        // A theme switch can change the desired height too (each theme has
        // its own default `panel.height`) when there's no user override.
        NotificationCenter.default.post(name: .desiredPanelHeightDidChange, object: nil)
    }

    private func watchActiveThemeFolder() {
        stopWatching()
        guard let folder = activeTheme?.folderURL else { return }

        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedDescriptor, fd >= 0 {
                close(fd)
            }
        }
        source.resume()
        watchedSource = source
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadActiveTheme()
        }
        reloadWorkItem = work
        // Small debounce: editors often emit several write events for one save.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func reloadActiveTheme() {
        guard let folder = activeTheme?.folderURL else { return }
        guard let reloaded = try? ThemeLoader.loadTheme(at: folder) else { return }
        activeTheme = reloaded
        watchActiveThemeFolder()
    }

    private func stopWatching() {
        watchedSource?.cancel()
        watchedSource = nil
    }

    deinit {
        stopWatching()
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
