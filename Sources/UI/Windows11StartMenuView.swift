import AppKit
import SwiftUI

/// Windows 11's own Start menu layout: search on top, no category sidebar —
/// just a grid of every installed app, most-recently-launched first, and an
/// account-name/power-button footer. An alternative to the default
/// Kickoff-style layout (see `StartMenuView`), picked via
/// `ThemeStore.startMenuStyle`.
struct Windows11StartMenuView: View {
    let appDiscovery: AppDiscovery
    let windowManager: WindowManager
    let theme: Theme
    let state: StartMenuState
    let liquidGlassEnabled: Bool
    let liquidGlassIntensity: Double
    let infiniteScroll: Bool
    let onLaunch: () -> Void

    private var tokens: ThemeTokens { theme.tokens }
    private static let columnCount = 6
    private let gridColumns = Array(repeating: GridItem(.flexible(minimum: 60), spacing: 12), count: Windows11StartMenuView.columnCount)

    /// Windows 11's own Start menu icons read noticeably larger than its
    /// taskbar's — twice the size of this bar's own icons, by explicit
    /// request, rather than matching them like the Kickoff layout does.
    private var iconSize: CGFloat { tokens.taskbarIconSize * 2 }

    /// Search results when there's a query, otherwise every installed app,
    /// most-recently-launched-through-this-app first (see
    /// `LaunchHistoryStore.sortedByRecency`) — no more separate "Épinglé"
    /// view, since the taskbar itself already shows pinned apps.
    private var displayedApps: [InstalledApp] {
        if !state.query.isEmpty {
            return appDiscovery.apps
                .filter { windowManager.matchesSearch(bundleIdentifier: $0.bundleIdentifier, realName: $0.displayName, query: state.query) }
        }
        return LaunchHistoryStore.sortedByRecency(appDiscovery.apps, bundleIdentifier: \.bundleIdentifier)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollViewReader { proxy in
                ThemedScrollView(proxy: proxy, accentColor: Color(hex: tokens.colors.accent), itemIDs: displayedApps.map(\.id), indicators: .never, state: state, loops: loopsEnabled) {
                    VStack(spacing: 12) {
                        if !state.query.isEmpty {
                            SearchExtrasView(query: state.query, tokens: tokens, onDone: onLaunch)
                        }
                        appGrid
                    }
                    .padding(20)
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    guard displayedApps.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(LoopList.id(copy: LoopList.middleCopy, slot: newIndex), anchor: .center)
                    }
                }
            }
            if state.query.isEmpty {
                RecommendedFilesView(tokens: tokens, onDone: onLaunch)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground(tokens: tokens, liquidGlassEnabled: liquidGlassEnabled, liquidGlassIntensity: liquidGlassIntensity, showTopBorder: false))
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
        // Only the top corners — the bottom edge sits flush against the
        // taskbar, so rounding it too would leave a visible gap/seam there.
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.topCornerRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: Self.topCornerRadius))
        .onAppear {
            state.selectedIndex = 0
            state.focusedRegion = .grid
        }
    }

    private static let topCornerRadius: CGFloat = 10

    private func moveSelection(_ direction: TextFieldNavigation) {
        let count = displayedApps.count
        guard count > 0 else { return }
        let columns = Self.columnCount
        var next = state.selectedIndex
        switch direction {
        case .up: next -= columns
        case .down: next += columns
        case .left: next -= 1
        case .right: next += 1
        }
        state.selectedIndex = min(max(0, next), count - 1)
    }

    private func launchSelected() {
        guard displayedApps.indices.contains(state.selectedIndex) else {
            SearchExtras.runPrimary(query: state.query, onDone: onLaunch)
            return
        }
        launch(displayedApps[state.selectedIndex])
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            ThemeIcon(url: theme.iconURL("search"), colorHex: tokens.colors.textSecondary, size: 14)
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: NSColor(Color(hex: tokens.colors.textPrimary)),
                accentColor: NSColor(Color(hex: tokens.colors.accent)),
                fontSize: tokens.typography.fontSize,
                onNavigate: { direction in moveSelection(direction) },
                onSubmit: launchSelected
            )
            .frame(height: 20)
        }
        .padding(10)
        .background(SearchFieldBackground(tokens: tokens, liquidGlassEnabled: liquidGlassEnabled, liquidGlassIntensity: liquidGlassIntensity))
        .padding(16)
    }

    private var loopsEnabled: Bool {
        LoopList.shouldLoop(enabled: infiniteScroll, searching: !state.query.isEmpty, count: displayedApps.count, columns: Self.columnCount, visibleRows: 4)
    }

    private var appGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(LoopList.entries(displayedApps, columns: Self.columnCount, loops: loopsEnabled)) { entry in
                if let app = entry.item {
                    appCell(app, isSelected: entry.slot == state.selectedIndex)
                        .id(entry.id)
                } else {
                    Color.clear.frame(height: 1).id(entry.id)
                }
            }
        }
        .scrollTargetLayout()
    }

    private func appCell(_ app: InstalledApp, isSelected: Bool) -> some View {
        Button {
            state.selectedIndex = displayedApps.firstIndex(where: { $0.id == app.id }) ?? state.selectedIndex
            launch(app)
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                Text(displayName(for: app))
                    .font(.system(size: tokens.typography.fontSize - 1))
                    .lineLimit(1)
                    .frame(width: iconSize + 20)
            }
            .padding(6)
            .background(isSelected ? Color(hex: tokens.colors.buttonBackgroundActive).opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(hex: tokens.colors.accent), lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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


    private var footer: some View {
        HStack {
            HStack(spacing: 8) {
                Button(action: AppleAccountSettings.open) {
                    Group {
                        if let photo = AccountPhoto.current() {
                            Image(nsImage: photo)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 20, height: 20)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 20))
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(L("account.open_settings"))
                Text(NSFullUserName())
                    .font(.system(size: tokens.typography.fontSize))
            }
            Spacer()
            NativeMenuButton(systemImage: "power", size: 16, tintColor: Color(hex: tokens.colors.textPrimary), makeMenu: sessionMenu)
        }
        .padding(12)
    }

    private func sessionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L("session.lock"), handler: SessionManager.lockScreen))
        menu.addItem(ClosureMenuItem(title: L("session.sleep"), handler: SessionManager.sleep))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("session.logout"), handler: SessionManager.logOut))
        menu.addItem(ClosureMenuItem(title: L("session.restart"), handler: SessionManager.restart))
        menu.addItem(ClosureMenuItem(title: L("session.shutdown"), handler: SessionManager.shutDown))
        return menu
    }
}
