import AppKit
import SwiftUI

/// Windows XP's Start menu: a blue header with the account picture and
/// name, a white column of programs on the left (with the search box under
/// it), a pale-blue column of places on the right, and a blue footer with
/// "Log Off" and "Turn Off Computer". Dressed in Luna's palette (Royale
/// Noir's, for the dark variant) — the colours are the style's own, not
/// read from the theme's tokens, which only carry the taskbar's.
struct WindowsXPStartMenuView: View {
    let appDiscovery: AppDiscovery
    let windowManager: WindowManager
    let theme: Theme
    let state: StartMenuState
    let infiniteScroll: Bool
    let onLaunch: () -> Void

    private var tokens: ThemeTokens { theme.tokens }
    /// Windows XP's own themes keep Luna's (and Royale Noir's) palettes; any
    /// other theme gets the same menu coloured from its own accent.
    private var palette: Palette {
        if theme.manifest.id.hasPrefix("windows-xp") { return theme.manifest.variant == "dark" ? .noir : .luna }
        return .derived(from: tokens)
    }
    private static let rowIconSize: CGFloat = 26
    private static let rightColumnWidth: CGFloat = 225
    private static let cornerRadius: CGFloat = 9

    private struct Palette {
        let headerTop: Color, headerBottom: Color, headerText: Color
        let leftBackground: Color, leftText: Color, leftSeparator: Color
        let rightBackground: Color, rightText: Color, rightBorder: Color
        let footerTop: Color, footerBottom: Color, footerText: Color
        let selection: Color, selectionText: Color
        let frame: Color
        /// The thin line under the header (Luna's orange).
        var headerLine: Color = Color(hex: "#F29B2C")
        /// Drop shadow under the white-on-blue header/footer text (none when themed).
        var textShadow: Color = .black.opacity(0.5)

        /// Any non-XP theme: surfaces, text and rules come from the theme's
        /// own bar colours; only the highlights use its accent.
        static func derived(from tokens: ThemeTokens) -> Palette {
            func c(_ hex: String) -> Color { Color(hex: hex) }
            let dark = tokens.isDarkTheme
            let panel = tokens.panel.backgroundColor
            let text = c(tokens.colors.textPrimary)
            let barTop = c(mixHex(panel, dark ? "#FFFFFF" : "#FFFFFF", dark ? 0.12 : 0.3))
            let barBottom = c(mixHex(panel, "#000000", dark ? 0.3 : 0.08))
            return Palette(
                headerTop: barTop, headerBottom: barBottom, headerText: text,
                leftBackground: c(dark ? mixHex(panel, "#000000", 0.3) : "#FFFFFF"), leftText: text, leftSeparator: c(tokens.colors.separator),
                rightBackground: c(mixHex(panel, tokens.colors.accent, 0.1)), rightText: text, rightBorder: c(tokens.colors.separator),
                footerTop: barTop, footerBottom: barBottom, footerText: text,
                selection: c(tokens.colors.accent), selectionText: c(tokens.colors.accentText),
                frame: c(tokens.colors.separator),
                headerLine: c(tokens.colors.accent),
                textShadow: .clear
            )
        }

        static let luna = Palette(
            headerTop: Color(hex: "#4B87E8"), headerBottom: Color(hex: "#1D4FC6"), headerText: .white,
            leftBackground: .white, leftText: Color(hex: "#000000"), leftSeparator: Color(hex: "#D9D9D9"),
            rightBackground: Color(hex: "#D3E5FA"), rightText: Color(hex: "#00136B"), rightBorder: Color(hex: "#95BDE7"),
            footerTop: Color(hex: "#3F7DDB"), footerBottom: Color(hex: "#1F55C4"), footerText: .white,
            selection: Color(hex: "#316AC5"), selectionText: .white,
            frame: Color(hex: "#0831D9")
        )
        static let noir = Palette(
            headerTop: Color(hex: "#5B5F6B"), headerBottom: Color(hex: "#24262B"), headerText: .white,
            leftBackground: Color(hex: "#2A2C31"), leftText: Color(hex: "#F2F2F4"), leftSeparator: Color(hex: "#43454D"),
            rightBackground: Color(hex: "#1B1C20"), rightText: Color(hex: "#E8EAF0"), rightBorder: Color(hex: "#43454D"),
            footerTop: Color(hex: "#3C3F48"), footerBottom: Color(hex: "#17181B"), footerText: .white,
            selection: Color(hex: "#3C81F3"), selectionText: .white,
            frame: Color(hex: "#0A0A0C")
        )
    }

    private var displayedApps: [InstalledApp] {
        if !state.query.isEmpty {
            return appDiscovery.apps
                .filter { windowManager.matchesSearch(bundleIdentifier: $0.bundleIdentifier, realName: $0.displayName, query: state.query) }
        }
        return LaunchHistoryStore.sortedByRecency(appDiscovery.apps, bundleIdentifier: \.bundleIdentifier)
    }

    private func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        tokens.font(size, weight: weight)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                leftColumn
                rightColumn
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.leftBackground)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: Self.cornerRadius))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: Self.cornerRadius)
                .strokeBorder(palette.frame, lineWidth: 1.5)
        )
        .onAppear {
            state.selectedIndex = 0
            state.focusedRegion = .grid
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: AppleAccountSettings.open) {
                Group {
                    if let photo = AccountPhoto.current() {
                        Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            }
            .buttonStyle(.plain)
            .help(L("account.open_settings"))
            Text(NSFullUserName())
                .font(font(17, weight: .bold))
                .foregroundStyle(palette.headerText)
                .shadow(color: palette.textShadow, radius: 0, x: 1, y: 1)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [palette.headerTop, palette.headerBottom], startPoint: .top, endPoint: .bottom)
                // The orange line under the header.
                LinearGradient(colors: [Color.clear, palette.headerLine, Color.clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
            }
        )
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            footerButton(symbol: "key.fill", symbolColor: Color(hex: "#F2C94C"), title: L("session.logout"), action: SessionManager.logOut)
            footerButton(symbol: "power", symbolColor: Color(hex: "#E5472B"), title: L("session.shutdown"), action: SessionManager.shutDown, filled: true)
            NativeMenuButton(systemImage: "chevron.up", size: 10, tintColor: palette.footerText, makeMenu: { StartMenuShortcuts.sessionMenu(logout: false, shutdown: false) })
                .frame(width: 22, height: 26)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(
            ZStack(alignment: .top) {
                LinearGradient(colors: [palette.footerTop, palette.footerBottom], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1)
            }
        )
    }

    private func footerButton(symbol: String, symbolColor: Color, title: String, action: @escaping () -> Void, filled: Bool = false) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(filled ? .white : symbolColor)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(filled ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "#E97B5A"), Color(hex: "#C23A1B")], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(0.18)))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                Text(title)
                    .font(font(12))
                    .foregroundStyle(palette.footerText)
                    .shadow(color: palette.textShadow, radius: 0, x: 0.5, y: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    // MARK: - Left column: programs + search

    private func moveSelection(_ direction: TextFieldNavigation) {
        let count = displayedApps.count
        guard count > 0 else { return }
        switch direction {
        case .up: state.selectedIndex = max(0, state.selectedIndex - 1)
        case .down: state.selectedIndex = min(count - 1, state.selectedIndex + 1)
        case .left, .right: break
        }
    }

    private func launchSelected() {
        guard displayedApps.indices.contains(state.selectedIndex) else {
            SearchExtras.runPrimary(query: state.query, onDone: onLaunch)
            return
        }
        launch(displayedApps[state.selectedIndex])
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                let apps = displayedApps
                let loops = LoopList.shouldLoop(enabled: infiniteScroll, searching: !state.query.isEmpty, count: apps.count, columns: 1, visibleRows: 12)
                ThemedScrollView(proxy: proxy, accentColor: palette.selection, itemIDs: apps.map(\.id), state: state, loops: loops) {
                    VStack(spacing: 6) {
                        if !state.query.isEmpty {
                            SearchExtrasView(query: state.query, tokens: tokens, onDone: onLaunch)
                        } else {
                            pinnedDefaults
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(LoopList.entries(apps, columns: 1, loops: loops)) { entry in
                                if let app = entry.item {
                                    HoverTrackedRow(state: state, id: app.id) { isHovered, isSelected in
                                        programRow(app, highlighted: isSelected(entry.slot) || isHovered)
                                    }
                                    .id(entry.id)
                                } else {
                                    Color.clear.frame(height: 1).id(entry.id)
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    guard displayedApps.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(LoopList.id(copy: LoopList.middleCopy, slot: newIndex), anchor: .center)
                    }
                }
            }
            Rectangle().fill(palette.leftSeparator).frame(height: 1).padding(.horizontal, 8)
            searchField
        }
        .frame(maxWidth: .infinity)
        .background(palette.leftBackground)
    }

    /// Luna's two pinned rows: the default browser ("Internet") and mail
    /// client ("E-mail"), each with its app name in grey underneath.
    private var pinnedDefaults: some View {
        VStack(spacing: 0) {
            pinnedRow(title: L("start.xp.internet"), url: NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!))
            pinnedRow(title: L("start.xp.email"), url: NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:a@b.c")!))
            Rectangle().fill(palette.leftSeparator).frame(height: 1).padding(.horizontal, 8).padding(.top, 4)
        }
    }

    @ViewBuilder
    private func pinnedRow(title: String, url: URL?) -> some View {
        if let url {
            let rowID = "xp-pinned-\(title)"
            let isHovered = state.hoveredRowID == rowID
            Button {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                onLaunch()
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(font(tokens.typography.fontSize, weight: .bold))
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(font(max(9, tokens.typography.fontSize - 2)))
                            .opacity(0.6)
                    }
                    .foregroundStyle(isHovered ? palette.selectionText : palette.leftText)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isHovered ? palette.selection : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                state.hoveredRowID = hovering ? rowID : (state.hoveredRowID == rowID ? nil : state.hoveredRowID)
            }
        }
    }

    private func programRow(_ app: InstalledApp, highlighted: Bool) -> some View {
        Button {
            state.selectedIndex = displayedApps.firstIndex(where: { $0.id == app.id }) ?? state.selectedIndex
            launch(app)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                    .resizable()
                    .frame(width: Self.rowIconSize, height: Self.rowIconSize)
                Text(displayName(for: app))
                    .font(font(tokens.typography.fontSize))
                    .foregroundStyle(highlighted ? palette.selectionText : palette.leftText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(highlighted ? palette.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(palette.leftText.opacity(0.55))
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: NSColor(palette.leftText),
                accentColor: NSColor(palette.selection),
                fontSize: tokens.typography.fontSize,
                onNavigate: { direction in moveSelection(direction) },
                onSubmit: launchSelected
            )
            .frame(height: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 3).fill(palette.leftBackground))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.rightBorder, lineWidth: 1))
        .padding(8)
    }

    // MARK: - Right column: places

    private var rightColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                placeRow(slot: "place-documents", icon: "doc.text.fill", color: "#E0A526", label: L("start.documents")) { StartMenuShortcuts.open(.documents); onLaunch() }
                placeRow(slot: "place-pictures", icon: "photo.fill", color: "#3B9A3B", label: L("start.pictures")) { StartMenuShortcuts.open(.pictures); onLaunch() }
                placeRow(slot: "place-music", icon: "music.note", color: "#C9553A", label: L("start.music")) { StartMenuShortcuts.open(.music); onLaunch() }
                placeRow(slot: "place-downloads", icon: "arrow.down.circle.fill", color: "#2D74D6", label: L("start.downloads")) { StartMenuShortcuts.open(.downloads); onLaunch() }
                placeRow(slot: "place-computer", icon: "desktopcomputer", color: "#5B7FB5", label: L("start.computer")) { StartMenuShortcuts.open(.home); onLaunch() }
                Rectangle().fill(palette.rightBorder).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 6)
                placeRow(slot: "place-settings", icon: "gearshape.fill", color: "#7A8696", label: L("start.control_panel"), bold: false, action: { StartMenuShortcuts.openSystemSettings(); onLaunch() })
                placeRow(slot: "place-trash", icon: "trash.fill", color: "#7A8696", label: L("app.trash"), bold: false) { StartMenuShortcuts.open(.trash); onLaunch() }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .frame(width: Self.rightColumnWidth)
        .frame(maxHeight: .infinity)
        .background(palette.rightBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.rightBorder).frame(width: 1)
        }
    }

    private func placeRow(slot: String, icon: String, color: String, label: String, bold: Bool = true, action: @escaping () -> Void) -> some View {
        let rowID = "xp-place-\(label)"
        let isHovered = state.hoveredRowID == rowID
        return Button(action: action) {
            HStack(spacing: 8) {
                ThemeGlyph(theme: theme, name: slot, fallbackSymbol: icon, size: 24, color: Color(hex: color))
                Text(label)
                    .font(font(tokens.typography.fontSize, weight: bold ? .bold : .regular))
                    .foregroundStyle(isHovered ? palette.selectionText : palette.rightText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(isHovered ? palette.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            state.hoveredRowID = hovering ? rowID : (state.hoveredRowID == rowID ? nil : state.hoveredRowID)
        }
    }


}
