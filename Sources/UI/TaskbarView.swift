import AppKit
import SwiftUI

/// Root content of the floating panel. Reads the active theme's `layout.json`
/// to decide which modules go in the left/center/right zones, and its
/// `tokens.json` to style them — no theme-specific code lives here.
struct TaskbarView: View {
    let themeStore: ThemeStore
    let windowManager: WindowManager
    let permissions: PermissionsManager
    let onMinimizeAll: () -> Void
    let startMenuState: StartMenuState

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
        let tokens = theme.tokens

        // One deterministic measurement of the panel's real width, instead
        // of nesting a second GeometryReader inside the HStack (that broke
        // vertical centering and let overflowing task buttons paint behind
        // the right zone instead of stopping at it).
        // The start button and "Réduire tout" render outside the padded
        // content, flush against the screen's leading/trailing edges — the
        // minimize button is then reachable by throwing the mouse into the
        // bottom-right corner, like a classic hot corner, instead of
        // stopping a few points short of it, and the start button sits as
        // far left as the screen allows, matching the same idea.
        let hasFlushStartButton = theme.layout.zones.left.contains("start-button")
        let leftModules = theme.layout.zones.left.filter { $0 != "start-button" }
        let hasFlushMinimizeAll = theme.layout.zones.right.contains("minimize-all")
        let rightModules = theme.layout.zones.right.filter { $0 != "minimize-all" }

        return GeometryReader { geometry in
            ZStack {
                background(tokens: tokens)

                HStack(spacing: tokens.spacing.itemSpacing) {
                    zone(leftModules, theme: theme)
                    centerZone(
                        theme.layout.zones.center,
                        theme: theme,
                        availableWidth: centerAvailableWidth(totalWidth: geometry.size.width, theme: theme)
                    )
                    zone(rightModules, theme: theme)
                }
                // The gap after the flush buttons' own estimated width
                // matches `itemSpacing` — the same spacing used between two
                // taskbar icons — instead of either the old dead gap
                // (edgePadding, too much) or none at all (too little).
                .padding(.leading, hasFlushStartButton ? estimatedZoneWidth(["start-button"], tokens: tokens) + tokens.spacing.itemSpacing : tokens.spacing.edgePadding)
                .padding(.trailing, hasFlushMinimizeAll ? estimatedZoneWidth(["minimize-all"], tokens: tokens) + tokens.spacing.itemSpacing : tokens.spacing.edgePadding)

                // Pinned to the geometry's own edges (not sequenced inside
                // the HStack above) so their clickable frame always reaches
                // all the way to the screen's leading/trailing edge — laying
                // them out as ordinary HStack siblings left their position
                // dependent on `estimatedZoneWidth`'s accuracy for every
                // other module, so any drift there shifted both flush
                // buttons away from the true edge instead of just changing
                // how much room the center zone got.
                if hasFlushStartButton {
                    HStack {
                        startButton(theme: theme)
                        Spacer(minLength: 0)
                    }
                }
                if hasFlushMinimizeAll {
                    HStack {
                        Spacer(minLength: 0)
                        minimizeAllButton(theme: theme)
                    }
                }
            }
        }
        .frame(height: tokens.panel.height)
        // Plain-style buttons (start, minimize-all, trash) still pick up
        // SwiftUI's default focus ring the moment they're clicked, drawn as
        // a highlighted outline around the button — this suppresses that
        // for the whole bar rather than every button individually.
        .focusEffectDisabled()
        .contextMenu {
            personalizationMenu
        }
    }

    /// Left/right zones are small and roughly fixed-size (start button,
    /// clock, minimize-all), so their width is estimated from the same
    /// formulas used to render them, rather than measured live — that
    /// keeps the center zone's budget a single deterministic number instead
    /// of a second, independently-negotiated flexible layout.
    private func centerAvailableWidth(totalWidth: CGFloat, theme: Theme) -> CGFloat {
        let tokens = theme.tokens
        let leftWidth = estimatedZoneWidth(theme.layout.zones.left, tokens: tokens)
        let rightWidth = estimatedZoneWidth(theme.layout.zones.right, tokens: tokens)
        let interZoneGaps = tokens.spacing.itemSpacing * 2 // between left↔center and center↔right
        let outerInsets = tokens.spacing.edgePadding * 2
        return max(0, totalWidth - leftWidth - rightWidth - interZoneGaps - outerInsets)
    }

    private func estimatedZoneWidth(_ modules: [String], tokens: ThemeTokens) -> CGFloat {
        var width: CGFloat = 0
        for (index, id) in modules.enumerated() {
            if index > 0 { width += tokens.spacing.itemSpacing }
            switch id {
            case "start-button":
                // Matches the actual render: same size as a taskbar app
                // icon (see `TaskButtonView.iconSize`), padded on both
                // sides.
                width += max(12, tokens.panel.height - 16) + tokens.spacing.edgePadding * 2
            case "minimize-all":
                width += tokens.panel.height - 8
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

    private static let sizePresets: [(key: String, height: Double)] = [
        ("tiny", 28),
        ("small", 36),
        ("medium", 44),
        ("large", 56),
        ("xlarge", 72),
        ("huge", 96)
    ]
    private static let sizeStep: Double = 2
    private static let minPanelHeight: Double = 22
    private static let maxPanelHeight: Double = 160

    /// Right-click on the taskbar: the customization menu.
    @ViewBuilder
    private var personalizationMenu: some View {
        Menu(L("menu.theme")) {
            ForEach(themeStore.availableThemes) { theme in
                Button {
                    themeStore.setActiveTheme(theme)
                } label: {
                    if theme.id == themeStore.activeTheme?.id {
                        Label(theme.manifest.name, systemImage: "checkmark")
                    } else {
                        Text(theme.manifest.name)
                    }
                }
            }
        }
        Menu(L("menu.bar_size")) {
            ForEach(Self.sizePresets, id: \.key) { preset in
                Button {
                    themeStore.panelHeightOverride = preset.height
                } label: {
                    let isSelected = (themeStore.panelHeightOverride ?? themeStore.activeTheme?.tokens.panel.height) == preset.height
                    if isSelected {
                        Label(L("size.\(preset.key)"), systemImage: "checkmark")
                    } else {
                        Text(L("size.\(preset.key)"))
                    }
                }
            }
            Divider()
            Button(L("size.increase")) { nudgePanelHeight(by: Self.sizeStep) }
            Button(L("size.decrease")) { nudgePanelHeight(by: -Self.sizeStep) }
            Button(L("size.custom")) { promptCustomHeight() }
            Divider()
            Text(L("size.hint"))
        }
        Menu(L("menu.open_apps")) {
            displayStyleItem(label: L("display.icon_and_label"), value: "iconAndLabel")
            displayStyleItem(label: L("display.icon_only"), value: "iconOnly")
        }
        Button {
            themeStore.liquidGlassEnabled.toggle()
        } label: {
            if themeStore.liquidGlassEnabled {
                Label(L("menu.liquid_glass"), systemImage: "checkmark")
            } else {
                Text(L("menu.liquid_glass"))
            }
        }
        Menu(L("menu.language")) {
            Button {
                themeStore.languageOverride = nil
            } label: {
                let systemLanguage = Localization.supportedLanguages.first { $0.code == Locale.preferredLanguages.first.map { String($0.prefix(2)) } }?.label
                    ?? Localization.supportedLanguages.first { $0.code == "fr" }!.label
                let label = L("language.system", ["lang": systemLanguage])
                if themeStore.languageOverride == nil {
                    Label(label, systemImage: "checkmark")
                } else {
                    Text(label)
                }
            }
            Divider()
            ForEach(Localization.supportedLanguages, id: \.code) { language in
                Button {
                    themeStore.languageOverride = language.code
                } label: {
                    if themeStore.languageOverride == language.code {
                        Label(language.label, systemImage: "checkmark")
                    } else {
                        Text(language.label)
                    }
                }
            }
        }
        Divider()
        Button(L("menu.quit")) {
            NSApp.terminate(nil)
        }
    }

    private func nudgePanelHeight(by delta: Double) {
        let current = themeStore.panelHeightOverride ?? Double(themeStore.effectivePanelHeight)
        themeStore.panelHeightOverride = min(Self.maxPanelHeight, max(Self.minPanelHeight, current + delta))
    }

    private func promptCustomHeight() {
        let current = themeStore.panelHeightOverride ?? Double(themeStore.effectivePanelHeight)

        let alert = NSAlert()
        alert.messageText = L("alert.custom_size.title")
        alert.informativeText = L("alert.custom_size.message", ["min": String(Int(Self.minPanelHeight)), "max": String(Int(Self.maxPanelHeight))])
        alert.addButton(withTitle: L("button.apply"))
        alert.addButton(withTitle: L("button.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(Int(current))
        field.alignment = .right
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn, let value = Double(field.stringValue) {
            themeStore.panelHeightOverride = min(Self.maxPanelHeight, max(Self.minPanelHeight, value))
        }
    }

    private func displayStyleItem(label: String, value: String) -> some View {
        Button {
            themeStore.taskDisplayStyleOverride = value
        } label: {
            if themeStore.effectiveTaskDisplayStyle == value {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
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
    private func centerZone(_ modules: [String], theme: Theme, availableWidth: CGFloat) -> some View {
        HStack(spacing: theme.tokens.spacing.itemSpacing) {
            ForEach(modules, id: \.self) { moduleID in
                if moduleID == "task-list" {
                    taskList(theme: theme, availableWidth: availableWidth)
                } else {
                    module(moduleID, theme: theme)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: availableWidth, height: theme.tokens.panel.height, alignment: .center)
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
        case "clock":
            clockView(tokens: tokens)
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
            startMenuState.isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                // No filled background: just the logo, sitting directly on
                // the panel. `textPrimary` (not `accentText`) since it's no
                // longer painted over an accent-colored square — it needs
                // to read against the panel's own background instead,
                // which differs between each theme's light/dark variant.
                // Same size as a taskbar app icon (`TaskButtonView.iconSize`
                // etc.) rather than its own fixed-per-theme size, so it
                // visually matches the icons sitting right next to it.
                ThemeIcon(url: theme.iconURL("start-button"), colorHex: tokens.colors.textPrimary, size: max(12, tokens.panel.height - 16))
                if tokens.startButton.showLabel {
                    Text(tokens.startButton.label)
                        .font(.system(size: tokens.typography.fontSize, weight: .medium))
                        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                        .padding(.trailing, tokens.spacing.edgePadding)
                }
            }
            .padding(.horizontal, tokens.spacing.edgePadding)
            .frame(height: tokens.panel.height)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        // No longer presented as a SwiftUI `.popover` — see
        // `StartMenuPanel`, a real resizable window that `TaskbarPanel`
        // shows/hides by observing `startMenuState.isPresented` directly.
    }

    @ViewBuilder
    private func taskList(theme: Theme, availableWidth: CGFloat) -> some View {
        let tokens = theme.tokens
        let entries = windowManager.entries
        let isIconOnly = tokens.taskButton.displayStyle == "iconOnly"

        // Buttons shrink towards an icon-only floor as more windows compete
        // for the same space, and cap at the theme's maxWidth when there's
        // plenty of room — instead of a fixed size that either wastes space
        // or overflows the panel.
        let iconOnlyWidth = max(24, tokens.panel.height - 8)
        let itemCount = max(1, entries.count)
        let perItemBudget = availableWidth / CGFloat(itemCount)
        let itemWidth = isIconOnly ? iconOnlyWidth : min(tokens.taskButton.maxWidth, max(iconOnlyWidth, perItemBudget))
        let showLabels = !isIconOnly && itemWidth >= iconOnlyWidth + 50

        HStack(spacing: tokens.spacing.itemSpacing) {
            // Pinned Dock launchers show up (and stay clickable) even
            // without Accessibility access; only real window control needs
            // that grant.
            ForEach(entries) { entry in
                switch entry {
                case .window(let window):
                    TaskButtonView(window: window, tokens: tokens, windowManager: windowManager, width: itemWidth, showLabel: showLabels) {
                        windowManager.activateOrMinimize(window)
                    }
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
                case .launcher(let app):
                    LauncherButtonView(app: app, tokens: tokens, windowManager: windowManager, width: itemWidth) {
                        windowManager.launch(app)
                    }
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
        }
    }

    private func minimizeAllButton(theme: Theme) -> some View {
        let tokens = theme.tokens
        return Button(action: onMinimizeAll) {
            ThemeIcon(url: theme.iconURL("show-desktop"), colorHex: tokens.colors.textPrimary, size: max(10, tokens.panel.height - 22))
                .frame(width: tokens.panel.height - 8, height: tokens.panel.height)
                .background(GlassButtonBackground(tokens: tokens, liquidGlassEnabled: themeStore.liquidGlassEnabled, liquidGlassIntensity: themeStore.liquidGlassIntensity))
                // Square, not rounded — same reasoning as the start button:
                // this one sits flush against the right edge/corner, and the
                // clickable area spans the full panel height (not inset)
                // so it actually reaches the bottom-right corner.
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(L("help.minimize_all"))
        // Same idea as macOS's "Active Corner → Desktop": dragging files
        // over this button briefly shows the desktop to drop them onto.
        .taskReorderable(bundleIdentifier: nil, windowManager: windowManager, onSpringLoad: onMinimizeAll)
    }

    private func trashButton(theme: Theme) -> some View {
        let tokens = theme.tokens
        return Button {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        } label: {
            ThemeIcon(url: theme.iconURL("trash"), colorHex: tokens.colors.textPrimary, size: max(10, tokens.panel.height - 22))
                .frame(width: tokens.panel.height - 8, height: tokens.panel.height - 8)
                .background(GlassButtonBackground(tokens: tokens, liquidGlassEnabled: themeStore.liquidGlassEnabled, liquidGlassIntensity: themeStore.liquidGlassIntensity, cornerRadius: tokens.taskButton.cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: tokens.taskButton.cornerRadius))
        }
        .buttonStyle(.plain)
        .help(L("help.trash"))
    }

    private func clockView(tokens: ThemeTokens) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.system(size: tokens.typography.fontSize, weight: .medium))
                .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                .padding(.horizontal, tokens.spacing.edgePadding)
        }
    }
}
