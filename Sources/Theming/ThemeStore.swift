import AppKit
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

/// Light/dark now chosen independently of which theme "family" is active —
/// every family ships both a `-light` and a `-dark` folder (same `id` minus
/// that suffix, same `manifest.name` minus " Light"/" Dark"), so picking a
/// family and a mode separately just means resolving to whichever of that
/// family's two folders matches.
enum ColorSchemeMode: String, CaseIterable {
    case light, dark, system
}

/// Which UI the start button opens — see `ThemeStore.startMenuStyle`.
enum StartMenuStyle: String, CaseIterable {
    /// The original Plasma Kickoff-style layout: search on top, a category
    /// sidebar on the left, a filterable app grid on the right.
    case kickoff
    /// Windows 11's Start menu: search on top, no sidebar, a grid of
    /// taskbar-pinned apps under "Épinglé" with a toggle to show every
    /// discovered app instead, an account-name/power-button footer.
    case windows11
    /// Opens the real, system Spotlight instead of any menu this app draws
    /// itself — see `SpotlightTrigger`.
    case realSpotlight
}

/// One theme "family" (e.g. "Breeze", "Windows 7") — a `-light`/`-dark`
/// pair grouped under a shared id/display name, for `ThemeStore`'s
/// mode-independent theme picker. See `ColorSchemeMode`.
struct ThemeFamily: Identifiable, Hashable {
    let id: String
    let displayName: String
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
    private static let selectedFamilyIDKey = "TB.theme.familyID"
    private static let colorSchemeModeKey = "TB.theme.colorSchemeMode"

    /// The currently chosen theme family (e.g. "breeze", "windows-7"),
    /// independent of light/dark — see `colorSchemeMode`. Setting this
    /// directly (rather than through `setActiveFamily`) would leave it out
    /// of sync with `activeTheme`, so it's only ever changed there.
    private(set) var selectedFamilyID: String = "breeze"

    /// Every distinct family across `availableThemes`, one entry per
    /// `-light`/`-dark` pair, for the Settings window's theme picker.
    var themeFamilies: [ThemeFamily] {
        var seen = Set<String>()
        var result: [ThemeFamily] = []
        for theme in availableThemes {
            let familyID = Self.familyID(for: theme)
            guard !seen.contains(familyID) else { continue }
            seen.insert(familyID)
            result.append(ThemeFamily(id: familyID, displayName: Self.familyDisplayName(for: theme)))
        }
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func familyID(for theme: Theme) -> String {
        let suffix = "-\(theme.manifest.variant)"
        return theme.id.hasSuffix(suffix) ? String(theme.id.dropLast(suffix.count)) : theme.id
    }

    private static func familyDisplayName(for theme: Theme) -> String {
        theme.manifest.name
            .replacingOccurrences(of: " Dark", with: "")
            .replacingOccurrences(of: " Light", with: "")
    }

    /// Picks `familyID`'s theme, persists the choice, and resolves it to
    /// the right light/dark variant for the current `colorSchemeMode`.
    func setActiveFamily(_ familyID: String) {
        selectedFamilyID = familyID
        UserDefaults.standard.set(familyID, forKey: Self.selectedFamilyIDKey)
        resolveActiveTheme()
    }

    private static let systemAppearanceChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")
    private var systemAppearanceObserver: NSObjectProtocol?

    /// Light, dark, or following the system's own appearance — independent
    /// of `selectedFamilyID`. Changing this re-resolves the active theme to
    /// that family's matching variant.
    var colorSchemeMode: ColorSchemeMode = .dark {
        didSet {
            guard colorSchemeMode != oldValue else { return }
            UserDefaults.standard.set(colorSchemeMode.rawValue, forKey: Self.colorSchemeModeKey)
            resolveActiveTheme()
        }
    }

    /// Resolves `selectedFamilyID` + `colorSchemeMode` to one of
    /// `availableThemes` and applies it. A family missing the resolved
    /// variant (shouldn't happen for the shipped themes, every one ships
    /// both) falls back to whichever variant it does have.
    private func resolveActiveTheme() {
        let variant: String
        switch colorSchemeMode {
        case .light: variant = "light"
        case .dark: variant = "dark"
        case .system: variant = isSystemDarkModeActive() ? "dark" : "light"
        }
        let candidates = availableThemes.filter { Self.familyID(for: $0) == selectedFamilyID }
        let resolved = candidates.first { $0.manifest.variant == variant } ?? candidates.first
        if let resolved {
            setActiveTheme(resolved)
        }
    }

    private func isSystemDarkModeActive() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func startObservingSystemAppearance() {
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.systemAppearanceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.colorSchemeMode == .system else { return }
            self.resolveActiveTheme()
        }
    }

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

    private static let autoHideEnabledKey = "TB.panel.autoHideEnabled"

    /// Windows-style auto-hide: the bar retracts off-screen (leaving a
    /// thin, hover-to-reveal sliver) when the mouse isn't near it — see
    /// `TaskbarPanel`'s own auto-hide tracking, which reads this.
    var autoHideEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoHideEnabled, forKey: Self.autoHideEnabledKey)
        }
    }

    private static let centerTaskListEnabledKey = "TB.panel.centerTaskListEnabled"

    /// When on, the center zone's content (the running-apps/launchers list,
    /// plus anything else a theme puts there) is centered within the bar
    /// instead of hugging its left edge — the bar's own background still
    /// spans the full screen width either way, only the icons move. Off by
    /// default, matching every theme's existing left-aligned look.
    var centerTaskListEnabled: Bool {
        didSet {
            UserDefaults.standard.set(centerTaskListEnabled, forKey: Self.centerTaskListEnabledKey)
        }
    }

    private static let centerIncludesStartButtonKey = "TB.panel.centerIncludesStartButton"

    /// Only meaningful alongside `centerTaskListEnabled`: when both are on,
    /// the start button moves out of its usual flush-left spot and becomes
    /// the leading item of the centered group instead, so it visually
    /// travels to the middle of the bar together with the icons rather than
    /// staying pinned to the screen's left edge.
    var centerIncludesStartButton: Bool {
        didSet {
            UserDefaults.standard.set(centerIncludesStartButton, forKey: Self.centerIncludesStartButtonKey)
        }
    }

    private static let clockEnabledKey = "TB.clock.enabled"

    /// Whether the clock module renders at all, for a theme that places one
    /// in its layout — on by default, matching every theme's existing look.
    var clockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clockEnabled, forKey: Self.clockEnabledKey)
        }
    }

    private static let clockShowDateKey = "TB.clock.showDate"

    /// Whether the date renders under the time — off by default (the
    /// clock's existing time-only look).
    var clockShowDate: Bool {
        didSet {
            UserDefaults.standard.set(clockShowDate, forKey: Self.clockShowDateKey)
        }
    }

    private static let startMenuStyleKey = "TB.startMenu.style"

    /// Which UI the start button opens — see `StartMenuStyle`.
    var startMenuStyle: StartMenuStyle = .kickoff {
        didSet {
            UserDefaults.standard.set(startMenuStyle.rawValue, forKey: Self.startMenuStyleKey)
        }
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
        autoHideEnabled = UserDefaults.standard.bool(forKey: Self.autoHideEnabledKey)
        centerTaskListEnabled = UserDefaults.standard.bool(forKey: Self.centerTaskListEnabledKey)
        centerIncludesStartButton = UserDefaults.standard.bool(forKey: Self.centerIncludesStartButtonKey)
        clockEnabled = (UserDefaults.standard.object(forKey: Self.clockEnabledKey) as? Bool) ?? true
        clockShowDate = UserDefaults.standard.bool(forKey: Self.clockShowDateKey)
        if let storedStyle = UserDefaults.standard.string(forKey: Self.startMenuStyleKey), let style = StartMenuStyle(rawValue: storedStyle) {
            startMenuStyle = style
        }
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

        // The pre-"family" version of this app persisted one exact theme
        // id (e.g. "breeze-dark") under `activeThemeIDKey` — used below as
        // a one-time migration source for whichever of the two new,
        // independent keys isn't set yet, so an existing user's prior pick
        // carries over as both their family *and* their initial light/dark
        // mode, instead of silently resetting either one.
        let legacyTheme = UserDefaults.standard.string(forKey: Self.activeThemeIDKey)
            .flatMap { id in availableThemes.first { $0.id == id } }

        if let storedFamily = UserDefaults.standard.string(forKey: Self.selectedFamilyIDKey) {
            selectedFamilyID = storedFamily
        } else if let legacyTheme {
            selectedFamilyID = Self.familyID(for: legacyTheme)
        } else if preferredThemeID.hasSuffix("-dark") {
            selectedFamilyID = String(preferredThemeID.dropLast(5))
        } else if preferredThemeID.hasSuffix("-light") {
            selectedFamilyID = String(preferredThemeID.dropLast(6))
        } else {
            selectedFamilyID = preferredThemeID
        }

        if let storedMode = UserDefaults.standard.string(forKey: Self.colorSchemeModeKey), let mode = ColorSchemeMode(rawValue: storedMode) {
            colorSchemeMode = mode
        } else if let legacyTheme {
            colorSchemeMode = legacyTheme.manifest.variant == "light" ? .light : .dark
        }

        // Direct assignments above may or may not have triggered
        // `colorSchemeMode`'s `didSet` (it's a no-op re-resolve if the
        // stored/migrated value happens to equal the inline default) — call
        // this once, unconditionally, so the very first launch always ends
        // up with a real `activeTheme` regardless.
        resolveActiveTheme()
        if activeTheme == nil, let first = availableThemes.first {
            setActiveTheme(first)
        }
        startObservingSystemAppearance()
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
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
        }
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
