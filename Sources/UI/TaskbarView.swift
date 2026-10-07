import AppKit
import SwiftUI

extension AnyTransition {
    /// A not-yet-pinned app's icon joining the taskbar for the first time —
    /// scales up from small while fading in, instead of just popping into
    /// existence at full size. See `TaskbarView.taskList`'s own use of it.
    static var taskbarAppearance: AnyTransition {
        .scale(scale: 0).combined(with: .opacity)
    }
}

/// Root content of the floating panel. Reads the active theme's `layout.json`
/// to decide which modules go in the left/center/right zones, and its
/// `tokens.json` to style them — no theme-specific code lives here.
struct TaskbarView: View {
    let themeStore: ThemeStore
    let windowManager: WindowManager
    let permissions: PermissionsManager
    let onMinimizeAll: () -> Void
    let startMenuState: StartMenuState
    /// Which bar this is (`TaskbarPanel.barID`) and, for every bar but the
    /// main one, which display it sits on.
    var barID = "primary"
    var displayID: CGDirectDisplayID?

    private var barScreen: NSScreen? {
        displayID.flatMap { id in NSScreen.screens.first { $0.displayID == id } } ?? DockController.dockScreen
    }

    /// What this bar lists when there's a bar per screen (see
    /// `WindowManager.BarScope`); `nil` when there's just the one.
    private var windowScope: WindowManager.BarScope? {
        guard themeStore.barOnAllScreensEnabled, NSScreen.screens.count > 1 else { return nil }
        return WindowManager.BarScope(displayID: barScreen?.displayID, isPrimary: displayID == nil)
    }

    var body: some View {
        Group {
            if let theme = themeStore.activeTheme {
                content(for: theme)
            } else {
                Text(L("app.no_theme"))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.barID, barID)
    }

    private func content(for originalTheme: Theme) -> some View {
        // A no-op read: establishes an Observation dependency on the
        // language override so this whole view re-renders on a language
        // change — none of the `L(...)` calls below read anything on
        // `themeStore` themselves, so without this nothing would.
        _ = themeStore.languageOverride

        // Override the theme's declared panel height with the effective one
        // (user size choice, floored by what the real Dock still reserves)
        // and thread that corrected copy everywhere instead of the raw
        // theme, so every nested view picks it up automatically.
        var theme = originalTheme
        theme.tokens.panel.height = themeStore.effectivePanelHeight
        theme.tokens.taskButton.displayStyle = themeStore.effectiveTaskDisplayStyle
        theme.tokens.taskbarIconRatio = themeStore.taskbarIconRatio
        theme.tokens.taskbarIconSpacingRatio = themeStore.taskbarIconSpacingRatio
        theme.tokens.taskbarIconHoverZoomRatio = themeStore.taskbarIconHoverZoomRatio
        if !themeStore.clockEnabled {
            // Strip it out of every zone up front, rather than just
            // rendering nothing where it would go — that would still leave
            // its slot's `itemSpacing` gap, and still reserve its estimated
            // width out of the center zone's budget.
            theme.layout.zones.left.removeAll { $0 == "clock" }
            theme.layout.zones.center.removeAll { $0 == "clock" }
            theme.layout.zones.right.removeAll { $0 == "clock" }
        }
        // The notification area sits right before the clock (or opens the
        // right zone when the clock is off).
        if themeStore.weatherEnabled && !themeStore.weatherOnRight { theme.layout.zones.left.append("weather") }
        // Right before the clock (or opening the right zone when the clock
        // is off): media, clipboard, screenshot, then the notification area.
        var beforeClock: [String] = []
        if themeStore.weatherEnabled && themeStore.weatherOnRight { beforeClock.append("weather") }
        if themeStore.mediaPlayerEnabled { beforeClock.append("media") }
        if themeStore.clipboardHistoryEnabled { beforeClock.append("clipboard") }
        if themeStore.screenshotButtonEnabled { beforeClock.append("screenshot") }
        if themeStore.systemTrayEnabled || themeStore.quickSettingsEnabled { beforeClock.append("tray") }
        if !beforeClock.isEmpty {
            if let index = theme.layout.zones.right.firstIndex(of: "clock") {
                theme.layout.zones.right.insert(contentsOf: beforeClock, at: index)
            } else if let index = theme.layout.zones.center.firstIndex(of: "clock") {
                theme.layout.zones.center.insert(contentsOf: beforeClock, at: index)
            } else if let index = theme.layout.zones.left.firstIndex(of: "clock") {
                theme.layout.zones.left.insert(contentsOf: beforeClock, at: index)
            } else {
                theme.layout.zones.right.insert(contentsOf: beforeClock, at: 0)
            }
        }
        let tokens = theme.tokens

        // One deterministic measurement of the panel's real width, instead
        // of nesting a second GeometryReader inside the HStack (that broke
        // vertical centering and let overflowing task buttons paint behind
        // the right zone instead of stopping at it).
        //
        // "Centrer avec le menu démarrer" moves the start button out of its
        // usual flush-left spot and into the centered group itself, so it
        // travels to the middle of the bar together with the icons — only
        // when the base centering option is also on, and only for a theme
        // that actually puts "start-button" in the left zone to begin with.
        let centerIncludesStart = themeStore.centerTaskListEnabled
            && themeStore.centerIncludesStartButton
            && theme.layout.zones.left.contains("start-button")
        let hasFlushStartButton = theme.layout.zones.left.contains("start-button") && !centerIncludesStart
        let leftModules = theme.layout.zones.left.filter { $0 != "start-button" }
        let hasFlushMinimizeAll = theme.layout.zones.right.contains("minimize-all")
        let rightModules = theme.layout.zones.right.filter { $0 != "minimize-all" }

        return GeometryReader { geometry in
            ZStack {
                background(tokens: tokens)
                    // Dropping an app from Finder onto empty bar background
                    // pins it too, not just when it lands directly on an
                    // existing icon (`taskReorderable`) — this sits behind
                    // every icon in the `ZStack`, so a drop that *does* land
                    // on one still reaches that icon's own drop target
                    // first.
                    .pinsDroppedApplications(windowManager: windowManager)

                // The start button and "Réduire tout" are ordinary
                // siblings in this same `HStack` now, not a separately
                // positioned overlay reserving space via an *estimate* of
                // their width — that estimate never quite matched their
                // real rendered width (icon vs. actual glyph metrics,
                // padding rounding, …), which is exactly what kept leaving
                // a stray gap next to the start button no matter how the
                // estimate was tuned. As ordinary siblings, the gap next to
                // them is just `itemSpacing`, the same spacing every other
                // pair of icons already uses — no estimate, so no possible
                // mismatch. Reaching the true screen edge (clickable area
                // included) still works: they're the first/last children
                // with that side's padding dropped to 0, and each already
                // sizes itself to the panel's full height.
                HStack(spacing: tokens.spacing.itemSpacing) {
                    if hasFlushStartButton {
                        startButton(theme: theme)
                    }
                    // `HStack`'s `spacing` applies between *every* pair of
                    // children it's given, even one that renders as
                    // completely empty — with only "start-button" in the
                    // left zone, `leftModules` is `[]`, but an empty
                    // `zone(...)` would still be a real (zero-width) child
                    // here, adding its own phantom `itemSpacing` gap.
                    // Omitting it entirely when there's nothing in it
                    // avoids that.
                    if !leftModules.isEmpty {
                        zone(leftModules, theme: theme)
                    }
                    centerZone(
                        theme.layout.zones.center,
                        theme: theme,
                        availableWidth: centerAvailableWidth(totalWidth: geometry.size.width, theme: theme, startButtonMovedToCenter: centerIncludesStart),
                        includeStartButton: centerIncludesStart
                    )
                    if !rightModules.isEmpty {
                        zone(rightModules, theme: theme)
                    }
                    if hasFlushMinimizeAll {
                        minimizeAllButton(theme: theme)
                    }
                }
                .padding(.leading, hasFlushStartButton ? 0 : tokens.spacing.edgePadding)
                .padding(.trailing, hasFlushMinimizeAll ? 0 : tokens.spacing.edgePadding)
            }
            // Named so `startButton(theme:)` can publish its own frame in
            // this same space — see `StartMenuState.startButtonFrame`.
            .coordinateSpace(name: Self.taskbarRootCoordinateSpace)
            // Hint that the top edge can be dragged to resize the bar while
            // icons are being edited (the drag itself is `BarResizeStripView`).
            .overlay(alignment: .top) {
                if windowManager.isEditingIcons {
                    Capsule()
                        .fill(Color(hex: tokens.colors.textSecondary).opacity(0.6))
                        .frame(width: 40, height: 3)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: windowManager.isEditingIcons)
        }
        .frame(height: tokens.panel.height)
        // Plain-style buttons (start, minimize-all, trash) still pick up
        // SwiftUI's default focus ring the moment they're clicked, drawn as
        // a highlighted outline around the button — this suppresses that
        // for the whole bar rather than every button individually.
        .focusEffectDisabled()
        // Right-click still opens a native `NSMenu` (see
        // `TaskbarContainerView`/`PersonalizationMenuBuilder`), but it now
        // only offers "Paramètres…"/"Quitter" — every actual setting moved
        // into `SettingsWindow`'s real, separate window instead.
    }

    /// Left/right zones are small and roughly fixed-size (start button,
    /// clock, minimize-all), so their width is estimated from the same
    /// formulas used to render them, rather than measured live — that
    /// keeps the center zone's budget a single deterministic number instead
    /// of a second, independently-negotiated flexible layout.
    private func centerAvailableWidth(totalWidth: CGFloat, theme: Theme, startButtonMovedToCenter: Bool) -> CGFloat {
        let tokens = theme.tokens
        // The start button no longer eats into the left zone's width once
        // it's rendered inside the centered group itself — it eats into
        // *this* budget instead, same as any other centered module.
        let leftZoneForWidth = startButtonMovedToCenter
            ? theme.layout.zones.left.filter { $0 != "start-button" }
            : theme.layout.zones.left
        let leftWidth = estimatedZoneWidth(leftZoneForWidth, tokens: tokens)
        let rightWidth = estimatedZoneWidth(theme.layout.zones.right, tokens: tokens)
        // Conversely, once it's a sibling inside the centered group, the
        // start button now shares (and shrinks) that group's own budget —
        // matching the extra `itemSpacing` gap it introduces there too.
        let startButtonInCenterWidth = startButtonMovedToCenter
            ? estimatedZoneWidth(["start-button"], tokens: tokens) + tokens.spacing.itemSpacing
            : 0
        let interZoneGaps = tokens.spacing.itemSpacing * 2 // between left↔center and center↔right
        let outerInsets = tokens.spacing.edgePadding * 2
        return max(0, totalWidth - leftWidth - rightWidth - startButtonInCenterWidth - interZoneGaps - outerInsets)
    }

    private func estimatedZoneWidth(_ modules: [String], tokens: ThemeTokens) -> CGFloat {
        var width: CGFloat = 0
        for (index, id) in modules.enumerated() {
            if index > 0 { width += tokens.spacing.itemSpacing }
            switch id {
            case "start-button":
                // Matches the actual render: same size as a taskbar app
                // icon (see `TaskButtonView.iconSize`), padded on the
                // leading side only now (no trailing padding).
                width += tokens.taskbarIconSize + tokens.spacing.edgePadding
            case "minimize-all":
                // Matches the actual render: a vertical strip half as wide
                // as it used to be.
                width += max(6, (tokens.panel.height - 8) / 2)
            case "weather":
                width += 70
            case "media", "clipboard", "screenshot":
                width += 32
            case "tray":
                width += 74
            case "clock":
                width += 64 // rough "HH:mm" + padding estimate; exact width depends on font metrics
            case "trash":
                width += tokens.panel.height - 8
            default:
                break
            }
        }
        return width
    }

    @ViewBuilder
    private func background(tokens: ThemeTokens) -> some View {
        PanelBackground(tokens: tokens, liquidGlassEnabled: themeStore.liquidGlassEnabled, liquidGlassIntensity: themeStore.liquidGlassIntensity)
    }

    @ViewBuilder
    private func zone(_ modules: [String], theme: Theme) -> some View {
        HStack(spacing: theme.tokens.spacing.itemSpacing) {
            ForEach(modules, id: \.self) { moduleID in
                module(moduleID, theme: theme)
            }
        }
    }

    /// The flexible middle zone. Takes its available width as a parameter
    /// (computed once in `content(for:)`) rather than measuring it with its
    /// own nested `GeometryReader`, and is explicitly sized + clipped to
    /// that width so its content can never paint past it into the right
    /// zone, and is vertically centered like the rest of the bar — a plain
    /// `GeometryReader` child defaults to top-leading, not centered.
    @ViewBuilder
    private func centerZone(_ modules: [String], theme: Theme, availableWidth: CGFloat, includeStartButton: Bool) -> some View {
        HStack(spacing: theme.tokens.spacing.itemSpacing) {
            // Centering just means giving this content a matching leading
            // Spacer too — the trailing one already left room for it to
            // shrink towards its natural width instead of stretching, so a
            // leading one splits that same leftover room evenly on both
            // sides instead of pushing it all to the right.
            if themeStore.centerTaskListEnabled {
                Spacer(minLength: 0)
            }
            // "Centrer avec le menu démarrer": the button travels here,
            // first in the centered group, instead of staying flush at the
            // panel's true left edge (see `content(for:)`'s `hasFlushStartButton`).
            if includeStartButton {
                startButton(theme: theme)
            }
            ForEach(modules, id: \.self) { moduleID in
                if moduleID == "task-list" {
                    taskList(theme: theme, availableWidth: availableWidth)
                } else {
                    module(moduleID, theme: theme)
                }
            }
            Spacer(minLength: 0)
        }
        // Flexible (fills whatever the outer `HStack` actually gives it),
        // not fixed to the *estimated* `availableWidth` — that estimate is
        // only ever "close enough" (font metrics, rounding), and a fixed
        // width here meant any error left the whole row's total width
        // short of or past the panel's real width. Since `HStack` has no
        // other flexible sibling, that error had nowhere to go but
        // centering slack on *both* outer edges — pushing the start
        // button and the minimize-all strip away from the true screen
        // edges by half the error each, even though neither of them was
        // what was actually miscalculated. Letting this zone absorb the
        // error instead keeps it exactly where a rounding mistake belongs:
        // invisible, inside the flexible task list, not at the panel's
        // edges.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: theme.tokens.panel.height)
        .clipped()
    }

    @ViewBuilder
    private func module(_ id: String, theme: Theme) -> some View {
        let tokens = theme.tokens
        switch id {
        case "start-button":
            startButton(theme: theme)
        case "minimize-all":
            minimizeAllButton(theme: theme)
        case "trash":
            trashButton(theme: theme)
        case "weather":
            WeatherWidget(tokens: tokens, themeStore: themeStore)
        case "media":
            MediaWidget(tokens: tokens, themeStore: themeStore)
        case "clipboard":
            ClipboardWidget(tokens: tokens, themeStore: themeStore)
        case "screenshot":
            ScreenshotWidget(tokens: tokens)
        case "tray":
            SystemTrayView(tokens: tokens, themeStore: themeStore)
        case "clock":
            clockView(tokens: tokens)
                .contentShape(Rectangle())
                .opensBarPopup("calendar", themeStore: themeStore) {
                    CalendarPopupView(tokens: tokens, extraTimeZones: themeStore.extraTimeZones)
                }
        default:
            // "task-list" only makes sense in the flexible center zone
            // (see `centerZone`), which measures the width it has to work
            // with before rendering it.
            EmptyView()
        }
    }

    private func startButton(theme: Theme) -> some View {
        let tokens = theme.tokens
        return Button {
            startMenuState.toggleOrHandOff(style: themeStore.startMenuStyle, screen: barScreen)
        } label: {
            HStack(spacing: 6) {
                // No filled background: just the logo, sitting directly on
                // the panel. `textPrimary` (not `accentText`) since it's no
                // longer painted over an accent-colored square — it needs
                // to read against the panel's own background instead,
                // which differs between each theme's light/dark variant.
                // Same size as a taskbar app icon (`TaskButtonView.iconSize`
                // etc.) rather than its own fixed-per-theme size, so it
                // visually matches the icons sitting right next to it —
                // except for a theme that explicitly asks to fill the
                // panel's whole height instead (Windows 7's Start orb,
                // drawn corner-to-corner in the real taskbar).
                StartButtonLift(isHovered: startMenuState.isStartButtonHovered, zoomRatio: tokens.effectiveTaskbarIconHoverZoom) {
                    ThemeIcon(
                        url: theme.iconURL("start-button"),
                        colorHex: tokens.colors.textPrimary,
                        size: tokens.startButton.fillHeight == true ? tokens.panel.height : tokens.taskbarIconSize
                    )
                }
                if tokens.startButton.showLabel {
                    Text(tokens.startButton.label)
                        .font(.system(size: tokens.typography.fontSize, weight: .medium))
                        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                        .padding(.trailing, tokens.spacing.edgePadding)
                }
            }
            // Leading padding only — no breathing room on the right, so
            // the icon sits as close as possible to whatever comes right
            // after it (the trailing edge was the actual source of the
            // lingering gap, not the task buttons' own alignment).
            .padding(.leading, tokens.spacing.edgePadding)
            .frame(height: tokens.panel.height)
        }
        .buttonStyle(PressReportingButtonStyle())
        .contentShape(Rectangle())
        .onHover { isHovering in
            startMenuState.isStartButtonHovered = isHovering
        }
        // No longer presented as a SwiftUI `.popover` — see
        // `StartMenuPanel`, a real resizable window that `TaskbarPanel`
        // shows/hides by observing `startMenuState.isPresented` directly.
        // Publishes this button's own frame so `StartMenuState`'s outside-
        // click monitor can tell a click *on the button* apart from a click
        // anywhere else on the bar (see `startButtonFrame`'s doc comment) —
        // tracked live since the button's position moves depending on the
        // "Centrer avec le menu démarrer" setting.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { startMenuState.startButtonFrames[barID] = geo.frame(in: .named(Self.taskbarRootCoordinateSpace)) }
                    .onChange(of: geo.frame(in: .named(Self.taskbarRootCoordinateSpace))) { _, newValue in
                        startMenuState.startButtonFrames[barID] = newValue
                    }
            }
        )
    }

    /// Named coordinate space the whole bar renders into (see
    /// `content(for:)`), shared with `startButton(theme:)` so it can report
    /// its own frame in a space that's directly comparable to an AppKit
    /// `NSEvent.locationInWindow` after a single Y-flip (this view's root
    /// fills the panel's entire window content area, so its origin lines up
    /// exactly with the window's own).
    /// Not `private` — `GroupedTaskButtonView` publishes its own frame into
    /// this same space too (see `WindowManager.groupButtonFrames`).
    static let taskbarRootCoordinateSpace = "taskbarRoot"

    /// The task list's entries, combined per the grouping setting. With
    /// "when the bar is full", each window keeps its own button for as long
    /// as they all fit at their smallest (an icon, plus a name when names are
    /// on); past that, same-app windows combine.
    private func taskEntries(grouping: TaskGroupingMode, isIconOnly: Bool, iconOnlyWidth: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [TaskbarEntry] {
        let entries = windowManager.entries(for: windowScope, grouped: grouping != .never)
        guard grouping == .whenFull else { return entries }
        let separate = windowManager.entries(for: windowScope, grouped: false)
        let smallest = (isIconOnly ? iconOnlyWidth : iconOnlyWidth + 50) + spacing
        return CGFloat(separate.count) * smallest <= availableWidth ? separate : entries
    }

    @ViewBuilder
    private func taskList(theme: Theme, availableWidth: CGFloat) -> some View {
        let tokens = theme.tokens
        let isIconOnly = tokens.taskButton.displayStyle == "iconOnly"
        let groupingMode = themeStore.groupingMode

        // Buttons shrink towards an icon-only floor as more windows compete
        // for the same space, and cap at the theme's maxWidth when there's
        // plenty of room — instead of a fixed size that either wastes space
        // or overflows the panel.
        //
        // Matches each button view's own icon size + horizontal padding
        // exactly (not just `panel.height`-derived, which could land
        // narrower than the icon+padding actually need) — otherwise the
        // icon's leading-aligned HStack overflows this frame asymmetrically,
        // throwing off both the icon's own centering and the active-window
        // underline (which spans this same width) relative to it.
        let iconOnlyWidth = max(24, tokens.taskbarIconSize + tokens.effectiveTaskbarEdgePadding * 2)
        let entries = taskEntries(grouping: groupingMode, isIconOnly: isIconOnly, iconOnlyWidth: iconOnlyWidth, spacing: tokens.effectiveTaskbarIconSpacing, availableWidth: availableWidth)
        let itemCount = max(1, entries.count)
        let perItemBudget = availableWidth / CGFloat(itemCount)
        let itemWidth = isIconOnly ? iconOnlyWidth : min(tokens.taskButton.maxWidth, max(iconOnlyWidth, perItemBudget))
        let showLabels = !isIconOnly && itemWidth >= iconOnlyWidth + 50

        HStack(spacing: tokens.effectiveTaskbarIconSpacing) {
            // Pinned Dock launchers show up (and stay clickable) even
            // without Accessibility access; only real window control needs
            // that grant.
            ForEach(entries) { entry in
                switch entry {
                case .window(let window):
                    TaskButtonView(window: window, tokens: tokens, windowManager: windowManager, width: itemWidth, showLabel: showLabels) {
                        windowManager.activateOrMinimize(window)
                    }
                    // A pinned app's launcher icon is already sitting right
                    // there when it opens — becoming a `.window` entry is
                    // just a state change in place, not a new icon joining
                    // the row, so it gets `.identity` (no transition at
                    // all). An unpinned app's icon genuinely didn't exist a
                    // moment ago; see `WindowManager.refresh`'s own
                    // `withAnimation` for what actually drives this
                    // transition (a plain `.animation(value:)` here wasn't
                    // reliable for a change driven by a different object).
                    .transition(windowManager.isPinned(bundleIdentifier: window.bundleIdentifier) ? .identity : .taskbarAppearance)
                case .group(let bundleIdentifier, let appName, let appIcon, let groupWindows):
                    GroupedTaskButtonView(
                        bundleIdentifier: bundleIdentifier,
                        appName: appName,
                        appIcon: appIcon,
                        windows: groupWindows,
                        tokens: tokens,
                        windowManager: windowManager,
                        width: itemWidth
                    )
                    .transition(windowManager.isPinned(bundleIdentifier: bundleIdentifier) ? .identity : .taskbarAppearance)
                case .launcher(let app):
                    // Always icon-only width, regardless of the "icon + name"
                    // setting or how wide open-window buttons are in this
                    // same row — a closed, pinned launcher never shows a
                    // name, so it shouldn't reserve room for one either.
                    LauncherButtonView(app: app, tokens: tokens, windowManager: windowManager, width: iconOnlyWidth) {
                        windowManager.launch(app)
                    }
                    // A launcher entry disappears for one of two reasons:
                    // the app just launched (about to reappear right here
                    // as a `.window`/`.group` entry instead — no animation,
                    // same as that insertion's own `.identity` case) or it
                    // was just unpinned (genuinely leaving the row for
                    // good). `isPinned` can't tell these apart — a
                    // `.launcher` entry only ever exists *because* its app
                    // is pinned, so at the moment one is being removed,
                    // `isPinned` is unconditionally still `true` either
                    // way, making that check a tautology here. Whether the
                    // app now has a running window does distinguish them:
                    // true only in the "just launched" case.
                    .transition(windowManager.windows.contains { $0.bundleIdentifier == app.bundleIdentifier } ? .identity : .taskbarAppearance)
                }
            }
            if !permissions.isTrusted {
                Button {
                    permissions.requestAccess()
                } label: {
                    Text(L("accessibility.prompt"))
                        .font(.system(size: tokens.typography.fontSize))
                        .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                }
                .buttonStyle(.plain)
            }
            Group {
                if windowManager.isEditingIcons {
                    doneEditingIconsButton(tokens: tokens)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: windowManager.isEditingIcons)
        }
    }

    /// The "jiggle mode" exit affordance (see `WindowManager.isEditingIcons`)
    /// — Escape does the same thing (`ShortcutsManager`), but a mouse-only
    /// user needs something to click, the same way iOS's own edit mode has
    /// always needed *some* way out for someone without a physical Escape
    /// key at all.
    private func doneEditingIconsButton(tokens: ThemeTokens) -> some View {
        Button {
            windowManager.isEditingIcons = false
        } label: {
            Text(L("icon_edit.done"))
                .font(.system(size: tokens.typography.fontSize, weight: .semibold))
                .foregroundStyle(Color(hex: tokens.colors.accentText))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(hex: tokens.colors.accent)))
        }
        .buttonStyle(.plain)
    }

    // No icon, half the previous width, with a visible frame — a plain
    // vertical strip, the way Windows 7's own "show desktop" sliver at the
    // far right of the taskbar looks (see the reference screenshot), in
    // place of the icon-in-a-square button used before.

    private func minimizeAllButton(theme: Theme) -> some View {
        let tokens = theme.tokens
        let width = max(6, (tokens.panel.height - 8) / 2)
        return Button(action: {
            // Apps hidden by the peek come back first, so the windows being
            // minimized are the real ones.
            windowManager.endDesktopPeek(restoringFocus: false)
            onMinimizeAll()
        }) {
            GlassButtonBackground(tokens: tokens, liquidGlassEnabled: themeStore.liquidGlassEnabled, liquidGlassIntensity: themeStore.liquidGlassIntensity)
                .frame(width: width, height: tokens.panel.height)
                // The same border as the bar's own top edge (`PanelBackground`),
                // so the button's top line continues the bar's. A theme with
                // no bar border keeps a thin neutral outline instead, so the
                // strip stays visible.
                .overlay {
                    if tokens.panel.borderWidth > 0 {
                        Rectangle().strokeBorder(Color(hex: tokens.panel.borderColor), lineWidth: tokens.panel.borderWidth)
                    } else {
                        Rectangle().strokeBorder(Color(hex: tokens.colors.textSecondary).opacity(0.5), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in windowManager.setDesktopPeek(hovering) }
        .help(L("help.minimize_all"))
        // Same idea as macOS's "Active Corner → Desktop": dragging files
        // over this button briefly shows the desktop to drop them onto.
        .taskReorderable(bundleIdentifier: nil, windowManager: windowManager, onSpringLoad: { windowManager.minimizeAll() })
    }

    private func trashButton(theme: Theme) -> some View {
        let tokens = theme.tokens
        return Button {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        } label: {
            TrashIcon(url: theme.iconURL("trash"), colorHex: tokens.colors.textPrimary, size: max(10, tokens.panel.height - 22), isOpen: windowManager.isTrashOpen)
                .frame(width: tokens.panel.height - 8, height: tokens.panel.height - 8)
                .background(GlassButtonBackground(tokens: tokens, liquidGlassEnabled: themeStore.liquidGlassEnabled, liquidGlassIntensity: themeStore.liquidGlassIntensity, cornerRadius: tokens.taskButton.cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: tokens.taskButton.cornerRadius))
        }
        .buttonStyle(.plain)
        .help(L("help.trash"))
        .trashesDroppedFiles()
        .contextMenu {
            Button(L("menu.empty_trash")) {
                TrashManager.emptyTrash()
            }
        }
    }

    private func clockView(tokens: ThemeTokens) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                // `.dateTime` styles order/format components (12h "1:38 PM"
                // vs. 24h "13:38", day/month order, …) from the environment
                // locale below, rather than from a hardcoded pattern — that
                // locale is the app's *chosen* language (see
                // `Localization.effectiveLocale`), not necessarily the
                // system's own region setting, since those two can disagree
                // (e.g. the language overridden to Russian on a Mac whose
                // system region is still French).
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: tokens.typography.fontSize, weight: .medium))
                    .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                if themeStore.clockShowDate {
                    Text(context.date, format: .dateTime.day().month().year())
                        .font(.system(size: max(8, tokens.typography.fontSize - 5)))
                        .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                }
            }
            .padding(.horizontal, tokens.spacing.edgePadding)
        }
        .environment(\.locale, Localization.effectiveLocale)
    }
}
