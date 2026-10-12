import AppKit
import SwiftUI

/// Windows 10's Start menu (the 20H2-and-later flat look): a narrow rail of
/// icons on the left (menu, account, Documents, Pictures, Settings, Power),
/// the apps in alphabetical sections with the most used on top, and — to the
/// right — the pinned apps as accent-coloured tiles. Coloured from the
/// theme: its panel colour behind, its accent on the tiles and the
/// selection.
struct Windows10StartMenuView: View {
    let appDiscovery: AppDiscovery
    let windowManager: WindowManager
    let theme: Theme
    let state: StartMenuState
    let liquidGlassEnabled: Bool
    let liquidGlassIntensity: Double
    let onLaunch: () -> Void

    private var tokens: ThemeTokens { theme.tokens }
    private static let railWidth: CGFloat = 48
    private static let listWidth: CGFloat = 270
    private static let tileSize: CGFloat = 96
    private static let tileSpacing: CGFloat = 4

    /// One line of the app list: a letter heading or an app.
    private enum Entry: Identifiable {
        case header(String)
        case app(InstalledApp, section: String)

        var id: String {
            switch self {
            case .header(let letter): return "header-\(letter)"
            case .app(let app, let section): return "\(section)|\(app.id)"
            }
        }
    }

    /// What the keyboard moves through, in list order.
    private var selectable: [InstalledApp] {
        entries.compactMap { if case .app(let app, _) = $0 { return app } else { return nil } }
    }

    private var entries: [Entry] {
        if !state.query.isEmpty {
            return appDiscovery.apps
                .filter { windowManager.matchesSearch(bundleIdentifier: $0.bundleIdentifier, realName: $0.displayName, query: state.query) }
                .map { .app($0, section: "search") }
        }
        var result: [Entry] = []
        let byRecency = LaunchHistoryStore.sortedByRecency(appDiscovery.apps, bundleIdentifier: \.bundleIdentifier)
        let mostUsed = Array(byRecency.prefix(3))
        if !mostUsed.isEmpty {
            result.append(.header(L("start.most_used")))
            result += mostUsed.map { .app($0, section: "top") }
        }
        let sorted = appDiscovery.apps.sorted { displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending }
        var currentLetter = ""
        for app in sorted {
            let letter = Self.letter(of: displayName(for: app))
            if letter != currentLetter {
                currentLetter = letter
                result.append(.header(letter))
            }
            result.append(.app(app, section: "all"))
        }
        return result
    }

    private static func letter(of name: String) -> String {
        guard let first = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased().first,
              first.isLetter else { return "#" }
        return String(first)
    }

    private var isDark: Bool { tokens.isDarkTheme }
    private var textColor: Color { Color(hex: tokens.colors.textPrimary) }
    private var dimColor: Color { Color(hex: tokens.colors.textSecondary) }
    private var accent: Color { Color(hex: tokens.colors.accent) }
    /// Windows 10's tiles are neutral translucent squares (accent only on request).
    private var tileColor: Color { Color.white.opacity(isDark ? 0.1 : 0.55) }

    var body: some View {
        HStack(spacing: 0) {
            rail
            appList
            tiles
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground(tokens: tokens, liquidGlassEnabled: liquidGlassEnabled, liquidGlassIntensity: liquidGlassIntensity, showTopBorder: false))
        .foregroundStyle(textColor)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 0))
        .onAppear {
            state.selectedIndex = 0
            state.focusedRegion = .grid
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: 0) {
            railButton("line.3.horizontal", help: L("start.apps")) {}
            Spacer(minLength: 0)
            railAccount
            railButton("doc", help: L("start.documents")) { StartMenuShortcuts.open(.documents); onLaunch() }
            railButton("photo", help: L("start.pictures")) { StartMenuShortcuts.open(.pictures); onLaunch() }
            railButton("gearshape", help: L("start.control_panel")) { StartMenuShortcuts.openSystemSettings(); onLaunch() }
            NativeMenuButton(systemImage: "power", size: 16, tintColor: textColor, makeMenu: { StartMenuShortcuts.sessionMenu() })
                .frame(width: Self.railWidth, height: 44)
        }
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity)
    }

    private var railAccount: some View {
        Button(action: AppleAccountSettings.open) {
            Group {
                if let photo = AccountPhoto.current() {
                    Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 22))
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
            .frame(width: Self.railWidth, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSFullUserName())
    }

    private func railButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        let id = "rail-\(symbol)"
        let isHovered = state.hoveredRowID == id
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: Self.railWidth, height: 44)
                .background(Color.white.opacity(isHovered ? 0.12 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            state.hoveredRowID = hovering ? id : (state.hoveredRowID == id ? nil : state.hoveredRowID)
        }
    }




    // MARK: - App list

    private func moveSelection(_ direction: TextFieldNavigation) {
        let count = selectable.count
        guard count > 0 else { return }
        switch direction {
        case .up: state.selectedIndex = max(0, state.selectedIndex - 1)
        case .down: state.selectedIndex = min(count - 1, state.selectedIndex + 1)
        case .left, .right: break
        }
    }

    private func launchSelected() {
        let apps = selectable
        guard apps.indices.contains(state.selectedIndex) else {
            SearchExtras.runPrimary(query: state.query, onDone: onLaunch)
            return
        }
        launch(apps[state.selectedIndex])
    }

    private var appList: some View {
        VStack(spacing: 0) {
            searchField
            ScrollViewReader { proxy in
                let list = entries
                ThemedScrollView(proxy: proxy, accentColor: accent, itemIDs: list.map(\.id), state: state, loops: false) {
                    LazyVStack(spacing: 0) {
                        if !state.query.isEmpty {
                            SearchExtrasView(query: state.query, tokens: tokens, onDone: onLaunch)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                        }
                        ForEach(list) { entry in
                            switch entry {
                            case .header(let title):
                                Text(title)
                                    .font(.system(size: tokens.typography.fontSize - 1, weight: .semibold))
                                    .foregroundStyle(dimColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .id(entry.id)
                            case .app(let app, _):
                                let index = selectable.firstIndex { $0.id == app.id } ?? 0
                                HoverTrackedRow(state: state, id: entry.id) { isHovered, isSelected in
                                    appRow(app, highlighted: isSelected(index) || isHovered)
                                }
                                .id(entry.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    guard selectable.indices.contains(newIndex),
                          let target = list.first(where: { if case .app(let app, _) = $0 { return app.id == selectable[newIndex].id } else { return false } }) else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target.id, anchor: .center) }
                }
            }
        }
        .frame(width: Self.listWidth)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(dimColor)
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: NSColor(textColor),
                accentColor: NSColor(accent),
                fontSize: tokens.typography.fontSize,
                onNavigate: { direction in moveSelection(direction) },
                onSubmit: launchSelected
            )
            .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(isDark ? 0.1 : 0.55))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(isDark ? 0.18 : 0.3), lineWidth: 1))
        .padding(10)
    }

    private func appRow(_ app: InstalledApp, highlighted: Bool) -> some View {
        Button {
            state.selectedIndex = selectable.firstIndex { $0.id == app.id } ?? state.selectedIndex
            launch(app)
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(displayName(for: app))
                    .font(.system(size: tokens.typography.fontSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(highlighted ? Color.white.opacity(isDark ? 0.14 : 0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            state.hoveredRowID = hovering ? "w10-\(app.id)" : (state.hoveredRowID == "w10-\(app.id)" ? nil : state.hoveredRowID)
        }
        .contextMenu {
            Button(windowManager.isPinned(bundleIdentifier: app.bundleIdentifier) ? L("taskbar.unpin") : L("taskbar.pin")) {
                windowManager.isPinned(bundleIdentifier: app.bundleIdentifier)
                    ? windowManager.unpin(url: app.url, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
                    : windowManager.pin(url: app.url, displayName: app.displayName)
            }
            Button(L("menu.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Button(L("menu.rename")) { windowManager.promptRename(bundleIdentifier: app.bundleIdentifier, currentName: displayName(for: app)) }
            if windowManager.hasCustomDisplayName(bundleIdentifier: app.bundleIdentifier) {
                Button(L("icon_edit.restore_original_name")) { windowManager.restoreOriginalDisplayName(for: app.bundleIdentifier) }
            }
            Divider()
            Button(L("app.trash")) { appDiscovery.confirmAndUninstall(app) }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.tileSize), spacing: Self.tileSpacing), count: 3)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("start.pinned"))
                    .font(.system(size: tokens.typography.fontSize, weight: .semibold))
                    .foregroundStyle(dimColor)
                    .padding(.top, 14)
                LazyVGrid(columns: columns, alignment: .leading, spacing: Self.tileSpacing) {
                    ForEach(windowManager.pinnedApps) { pinned in
                        tile(pinned)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity)
    }

    private func tile(_ pinned: PinnedApp) -> some View {
        let id = "tile-\(pinned.id)"
        let isHovered = state.hoveredRowID == id
        return Button {
            NSWorkspace.shared.openApplication(at: pinned.url, configuration: NSWorkspace.OpenConfiguration())
            LaunchHistoryStore.recordLaunch(bundleIdentifier: pinned.bundleIdentifier)
            onLaunch()
        } label: {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(tileColor)
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: pinned.bundleIdentifier, fallback: pinned.icon) ?? pinned.icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 12)
                Text(windowManager.resolvedDisplayName(bundleIdentifier: pinned.bundleIdentifier, fallback: pinned.displayName))
                    .font(.system(size: tokens.typography.fontSize - 2))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 5)
            }
            .frame(width: Self.tileSize, height: Self.tileSize)
            .overlay(Rectangle().strokeBorder(textColor.opacity(isHovered ? 0.45 : 0), lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            state.hoveredRowID = hovering ? id : (state.hoveredRowID == id ? nil : state.hoveredRowID)
        }
        .contextMenu {
            Button(L("taskbar.unpin")) {
                windowManager.unpin(url: pinned.url, bundleIdentifier: pinned.bundleIdentifier, displayName: pinned.displayName)
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
}
