import AppKit
import SwiftUI

/// Windows 7's Start menu: a plain, dense list of pinned programs (with an
/// "All Programs" view that replaces it in place) and a search box on the
/// left; an account picture and quick system/folder links on a tinted
/// right-hand column; a split Shut Down button at the bottom-right,
/// mirrored by the search box at the bottom-left — matching the real
/// thing's layout exactly. An alternative to the Kickoff/Windows 11
/// layouts, picked via `ThemeStore.startMenuStyle`.
struct Windows7StartMenuView: View {
    let appDiscovery: AppDiscovery
    let windowManager: WindowManager
    let theme: Theme
    let state: StartMenuState
    let liquidGlassEnabled: Bool
    let liquidGlassIntensity: Double
    let infiniteScroll: Bool
    let onLaunch: () -> Void

    private var tokens: ThemeTokens { theme.tokens }
    private var isDark: Bool { theme.manifest.variant == "dark" }

    /// The menu's own Aero look — a pane of tinted glass with a white
    /// programs list on the left and white-on-glass text on the right —
    /// whatever the theme's text colours are, so it reads like the real
    /// thing instead of taking the taskbar's flat grays.
    /// Windows 7 and Vista keep Aero's own blues; any other theme gets the
    /// same menu tinted with its own accent colour.
    private var usesAeroBlue: Bool { theme.manifest.id.hasPrefix("windows-7") || theme.manifest.id.hasPrefix("windows-vista") }
    private var accentHex: String { tokens.colors.accent }
    /// Any theme other than Windows 7/Vista: the menu is built from the
    /// theme's own surface, text and accent colours, so it matches its bar.
    private var themedFg: Color { Color(hex: tokens.colors.textPrimary) }
    /// Text and rules on the glass (right column, shutdown pill).
    private var fg: Color { usesAeroBlue ? .white : themedFg }
    private var textShadow: Color { usesAeroBlue ? .black.opacity(0.35) : .clear }
    /// The programs pane's fill and text.
    private var paneFill: Color {
        if usesAeroBlue { return Color.white.opacity(0.96) }
        return tokens.isDarkTheme ? Color(hex: mixHex(tokens.panel.backgroundColor, "#000000", 0.3)) : .white
    }
    private var paneText: Color { usesAeroBlue ? Color(hex: "#111111") : themedFg }

    private var glassTint: LinearGradient {
        if !usesAeroBlue {
            return LinearGradient(colors: [Color(hex: mixHex(accentHex, "#000000", 0.15)).opacity(0.72), Color(hex: mixHex(accentHex, "#000000", 0.6)).opacity(0.86)], startPoint: .top, endPoint: .bottom)
        }
        return isDark
            ? LinearGradient(colors: [Color(hex: "#34414F").opacity(0.78), Color(hex: "#0A1018").opacity(0.86)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(hex: "#5A8DB0").opacity(0.7), Color(hex: "#1E4A66").opacity(0.82)], startPoint: .top, endPoint: .bottom)
    }
    private var selectionBorder: Color { Color(hex: usesAeroBlue ? "#7DA2CE" : accentHex).opacity(usesAeroBlue ? 1 : 0.8) }
    private var selectionGradient: LinearGradient {
        usesAeroBlue
            ? LinearGradient(colors: [Color(hex: "#E3EFFD"), Color(hex: "#B5D3F2")], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(hex: accentHex).opacity(0.3), Color(hex: accentHex).opacity(0.5)], startPoint: .top, endPoint: .bottom)
    }
    private var hoverGradient: LinearGradient {
        usesAeroBlue
            ? LinearGradient(colors: [Color(hex: "#F0F6FE"), Color(hex: "#D5E6F8")], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(hex: accentHex).opacity(0.12), Color(hex: accentHex).opacity(0.24)], startPoint: .top, endPoint: .bottom)
    }

    /// Tokens for text drawn on the white programs pane (the theme's own may
    /// be white-on-glass).
    private var paneTokens: ThemeTokens {
        guard usesAeroBlue else { return tokens }
        var t = tokens
        t.colors.textPrimary = "#111111"
        t.colors.textSecondary = "#5A5F66"
        t.colors.buttonBackgroundHover = "#DCEBFC"
        return t
    }
    private static let rowIconSize: CGFloat = 24
    private static let rightColumnWidth: CGFloat = 200
    private static let topCornerRadius: CGFloat = 10

    /// Every installed app — search results when there's a query, otherwise
    /// every app, most-recently-launched-through-this-app first (see
    /// `LaunchHistoryStore.sortedByRecency`). No more "Pinned"/"All
    /// Programs" toggle: the taskbar itself already shows pinned apps, so a
    /// second, separate pinned view here was pure redundancy.
    private var displayedApps: [InstalledApp] {
        if !state.query.isEmpty {
            return appDiscovery.apps
                .filter { windowManager.matchesSearch(bundleIdentifier: $0.bundleIdentifier, realName: $0.displayName, query: state.query) }
        }
        return LaunchHistoryStore.sortedByRecency(appDiscovery.apps, bundleIdentifier: \.bundleIdentifier)
    }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
            rightColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Group {
                if usesAeroBlue {
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, appearance: NSAppearance(named: .darkAqua))
                        glassTint
                        // The glass's soft top sheen.
                        LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                    }
                } else {
                    // Same surface as the theme's bar and its other menus.
                    PanelBackground(tokens: tokens, liquidGlassEnabled: liquidGlassEnabled, liquidGlassIntensity: liquidGlassIntensity, showTopBorder: false)
                }
            }
        )
        .foregroundStyle(fg)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.topCornerRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: Self.topCornerRadius))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: Self.topCornerRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: Self.topCornerRadius)
                .strokeBorder(usesAeroBlue ? Color.white.opacity(0.45) : Color(hex: tokens.colors.separator), lineWidth: 1)
        )
        .onAppear {
            state.selectedIndex = 0
            state.focusedRegion = .grid
        }
    }

    private func moveSelection(_ direction: TextFieldNavigation) {
        let count = displayedApps.count
        guard count > 0 else { return }
        switch direction {
        case .up: state.selectedIndex = max(0, state.selectedIndex - 1)
        case .down: state.selectedIndex = min(count - 1, state.selectedIndex + 1)
        case .left, .right: break // a single column: no horizontal movement
        }
    }

    private func launchSelected() {
        guard displayedApps.indices.contains(state.selectedIndex) else {
            SearchExtras.runPrimary(query: state.query, onDone: onLaunch)
            return
        }
        launch(displayedApps[state.selectedIndex])
    }

    // MARK: - Left column: programs + search

    private var leftColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                // Computed once per render and reused — `displayedApps` sorts
                // and filters every app each time it's read.
                let apps = displayedApps
                let loops = LoopList.shouldLoop(enabled: infiniteScroll, searching: !state.query.isEmpty, count: apps.count, columns: 1, visibleRows: 14)
                ThemedScrollView(proxy: proxy, accentColor: Color(hex: tokens.colors.accent), itemIDs: apps.map(\.id), state: state, loops: loops) {
                    VStack(spacing: 6) {
                    if !state.query.isEmpty {
                        SearchExtrasView(query: state.query, tokens: paneTokens, onDone: onLaunch)
                    }
                    LazyVStack(spacing: 1) {
                        ForEach(LoopList.entries(apps, columns: 1, loops: loops)) { entry in
                            if let app = entry.item {
                                // Hover and selection are read inside the
                                // wrapper's own body, not this one: scrolling
                                // moves rows under a still mouse, firing hover
                                // changes constantly, and each one used to
                                // re-run this whole body (re-sorting every app).
                                // Now only the rows whose state changed redraw.
                                HoverTrackedRow(state: state, id: app.id) { isHovered, isSelected in
                                    programRow(app, isSelected: isSelected(entry.slot), isHovered: isHovered)
                                }
                                .id(entry.id)
                            } else {
                                Color.clear.frame(height: 1).id(entry.id)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    }
                    .padding(6)
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    guard displayedApps.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(LoopList.id(copy: LoopList.middleCopy, slot: newIndex), anchor: .center)
                    }
                }
            }
            Rectangle().fill(Color(hex: usesAeroBlue ? "#D7DEE8" : tokens.colors.separator)).frame(height: 1).padding(.horizontal, 6)
            searchField
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(paneText)
        // The white programs pane, inset in the glass frame.
        .background(RoundedRectangle(cornerRadius: 4).fill(paneFill))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(usesAeroBlue ? Color.black.opacity(0.35) : Color(hex: tokens.colors.separator), lineWidth: 1))
        .padding(.leading, 6)
        .padding(.vertical, 6)
        .padding(.trailing, 2)
    }

    private func programRow(_ app: InstalledApp, isSelected: Bool, isHovered: Bool) -> some View {
        Button {
            state.selectedIndex = displayedApps.firstIndex(where: { $0.id == app.id }) ?? state.selectedIndex
            launch(app)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                    .resizable()
                    .frame(width: Self.rowIconSize, height: Self.rowIconSize)
                Text(displayName(for: app))
                    .font(.system(size: tokens.typography.fontSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                // Aero's own selection highlight is a glassy gradient, not a
                // flat tint — darker at the bottom than the top, with a
                // bright sliver right at the top edge to read as "glossy".
                // A hovered-but-not-selected row gets the same treatment,
                // just fainter, so moving the mouse down the list previews
                // what clicking (or arrowing onto it) would look like.
                isSelected
                    ? selectionGradient
                    : isHovered
                        ? hoverGradient
                        : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selectionBorder.opacity(isSelected ? 1 : (isHovered ? 0.7 : 0)), lineWidth: 1)
        )
        .onHover { hovering in
            state.hoveredRowID = hovering ? app.id : (state.hoveredRowID == app.id ? nil : state.hoveredRowID)
        }
        .contextMenu {
            Button(windowManager.isPinned(bundleIdentifier: app.bundleIdentifier) ? L("taskbar.unpin") : L("taskbar.pin")) {
                windowManager.isPinned(bundleIdentifier: app.bundleIdentifier)
                    ? windowManager.unpin(url: app.url, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
                    : windowManager.pin(url: app.url, displayName: app.displayName)
            }
            Button(L("menu.show_in_finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            Button(L("menu.rename")) {
                windowManager.promptRename(bundleIdentifier: app.bundleIdentifier, currentName: displayName(for: app))
            }
            if windowManager.hasCustomDisplayName(bundleIdentifier: app.bundleIdentifier) {
                Button(L("icon_edit.restore_original_name")) {
                    windowManager.restoreOriginalDisplayName(for: app.bundleIdentifier)
                }
            }
            Divider()
            Button(L("app.trash")) {
                appDiscovery.confirmAndUninstall(app)
            }
        }
    }

    private func displayName(for app: InstalledApp) -> String {
        windowManager.resolvedDisplayName(bundleIdentifier: app.bundleIdentifier, fallback: app.displayName)
    }

    private func launch(_ app: InstalledApp) {
        LaunchHistoryStore.recordLaunch(bundleIdentifier: app.bundleIdentifier)
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        onLaunch()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: NSColor(paneText),
                accentColor: NSColor(Color(hex: tokens.colors.accent)),
                fontSize: tokens.typography.fontSize,
                onNavigate: { direction in moveSelection(direction) },
                onSubmit: launchSelected
            )
            .frame(height: 18)
            // On the right, as in the real menu's search box.
            ThemeIcon(url: theme.iconURL("search"), colorHex: usesAeroBlue ? "#4A78B0" : accentHex, size: 13)
        }
        // Without this, the HStack above only ever sizes to fit its own
        // content (icon + placeholder text) — no amount of padding on the
        // *outside* can push a edge that was never reaching the column's
        // true width in the first place. This is what actually makes the
        // field's background span the row, not just look roughly
        // full-width by coincidence.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 3).fill(usesAeroBlue ? Color.white : paneFill))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selectionBorder, lineWidth: 1))
        // Left matches the program list's own `.padding(6)` above (see
        // `leftColumn`). Right is flush (0), not also 6 — the list sits in
        // a plain `ScrollView` with no outer padding of its own, so its
        // scrollbar (never shown, but the list still ends at that
        // edge) tracks the column's true trailing edge, not
        // the 6pt-inset one the *rows* happen to stop at. Matching the
        // field's own trailing edge to that same true edge is what lines
        // the two up.
        .padding(.leading, 6)
    }

    // MARK: - Right column: account + quick links + shut down

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountHeader
            // Plain white links, no icons, with faint rules between the
            // groups — as in the real menu.
            VStack(alignment: .leading, spacing: 1) {
                quickLinkRow(label: NSFullUserName(), action: AppleAccountSettings.open)
                quickLinkRow(label: L("start.documents")) { StartMenuShortcuts.open(.documents); onLaunch() }
                quickLinkRow(label: L("start.pictures")) { StartMenuShortcuts.open(.pictures); onLaunch() }
                quickLinkRow(label: L("start.music")) { StartMenuShortcuts.open(.music); onLaunch() }
                quickLinkRow(label: L("start.downloads")) { StartMenuShortcuts.open(.downloads); onLaunch() }
                rule
                quickLinkRow(label: L("start.computer")) { StartMenuShortcuts.open(.home); onLaunch() }
                rule
                quickLinkRow(label: L("start.control_panel"), action: { StartMenuShortcuts.openSystemSettings(); onLaunch() })
                quickLinkRow(label: L("app.trash")) { StartMenuShortcuts.open(.trash); onLaunch() }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
            shutDownRow
        }
        .frame(width: Self.rightColumnWidth)
        .foregroundStyle(fg)
    }

    private var rule: some View {
        Rectangle().fill(fg.opacity(0.22)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 6)
    }

    /// The account picture, centred on the right column.
    private var accountHeader: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: AppleAccountSettings.open) {
                Group {
                    if let photo = AccountPhoto.current() {
                        Image(nsImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Image(systemName: "person.crop.square.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(fg.opacity(0.8))
                            .frame(width: 54, height: 54)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(fg.opacity(0.85), lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help(L("account.open_settings"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func quickLinkRow(label: String, action: @escaping () -> Void) -> some View {
        let rowID = "quick-\(label)"
        let isHovered = state.hoveredRowID == rowID
        return Button(action: action) {
            Text(label)
                .font(.system(size: tokens.typography.fontSize))
                .lineLimit(1)
                .foregroundStyle(fg)
                .shadow(color: textShadow, radius: 1, y: 0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [fg.opacity(isHovered ? 0.3 : 0), fg.opacity(isHovered ? 0.12 : 0)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(fg.opacity(isHovered ? 0.4 : 0), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            state.hoveredRowID = hovering ? rowID : (state.hoveredRowID == rowID ? nil : state.hoveredRowID)
        }
    }



    /// The small dark-glass "Shut down" button with its arrow, at the foot
    /// of the right column.
    private var shutDownRow: some View {
        HStack(spacing: 0) {
            Button(action: SessionManager.shutDown) {
                Text(L("session.shutdown"))
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(fg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            Rectangle().fill(fg.opacity(0.3)).frame(width: 1)
            NativeMenuButton(systemImage: "chevron.right", size: 9, tintColor: fg, makeMenu: { StartMenuShortcuts.sessionMenu(logout: true, shutdown: false) })
                .frame(width: 22, height: 24)
        }
        .background(
            LinearGradient(
                stops: usesAeroBlue
                    ? [.init(color: Color(hex: "#6C7C8B"), location: 0), .init(color: Color(hex: "#3F4D5A"), location: 0.5), .init(color: Color(hex: "#2B3743"), location: 0.5), .init(color: Color(hex: "#475869"), location: 1)]
                    : [.init(color: Color(hex: mixHex(tokens.colors.buttonBackground, "#FFFFFF", 0.15)), location: 0), .init(color: Color(hex: tokens.colors.buttonBackground), location: 0.5), .init(color: Color(hex: mixHex(tokens.colors.buttonBackground, "#000000", 0.1)), location: 0.5), .init(color: Color(hex: tokens.colors.buttonBackground), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: 26)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(fg.opacity(0.4), lineWidth: 1))
        .padding(.leading, 12)
        .padding(.bottom, 10)
    }

}

/// Reads `state.hoveredRowID` and `state.selectedIndex` in *its own* `body`,
/// so Observation only invalidates the rows those values actually affect —
/// not `Windows7StartMenuView.body`, which re-sorts every installed app.
struct HoverTrackedRow<Content: View>: View {
    let state: StartMenuState
    let id: String
    let content: (_ isHovered: Bool, _ isSelected: (Int) -> Bool) -> Content

    var body: some View {
        content(state.hoveredRowID == id) { index in index == state.selectedIndex }
    }
}
