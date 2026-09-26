import AppKit
import SwiftUI

/// Windows 11's own Start menu layout: search on top, no category sidebar —
/// just a grid of taskbar-pinned apps under "Épinglé", with a toggle to
/// show every discovered app instead, and an account-name/power-button
/// footer. An alternative to the default Kickoff-style layout (see
/// `StartMenuView`), picked via `ThemeStore.startMenuStyle`.
struct Windows11StartMenuView: View {
    let appDiscovery: AppDiscovery
    let windowManager: WindowManager
    let theme: Theme
    let state: StartMenuState
    let liquidGlassEnabled: Bool
    let liquidGlassIntensity: Double
    let onLaunch: () -> Void

    private var tokens: ThemeTokens { theme.tokens }
    private static let columnCount = 6
    private let gridColumns = Array(repeating: GridItem(.flexible(minimum: 60), spacing: 12), count: Windows11StartMenuView.columnCount)

    /// Windows 11's own Start menu icons read noticeably larger than its
    /// taskbar's — twice the size of this bar's own icons, by explicit
    /// request, rather than matching them like the Kickoff layout does.
    private var iconSize: CGFloat { tokens.taskbarIconSize * 2 }

    /// A single grid cell's app, whichever list it came from — unifies
    /// `PinnedApp` (the default, empty-search view) and `InstalledApp`
    /// (search results, or "Toutes les applications") so one grid can
    /// render either without duplicating layout code.
    private enum DisplayApp: Identifiable {
        case pinned(PinnedApp)
        case installed(InstalledApp)

        var id: String {
            switch self {
            case .pinned(let app): "p-\(app.id)"
            case .installed(let app): "i-\(app.id)"
            }
        }
        var displayName: String {
            switch self {
            case .pinned(let app): app.displayName
            case .installed(let app): app.displayName
            }
        }
        var icon: NSImage {
            switch self {
            case .pinned(let app): app.icon
            case .installed(let app): app.icon
            }
        }
        var bundleIdentifier: String? {
            switch self {
            case .pinned(let app): app.bundleIdentifier
            case .installed(let app): app.bundleIdentifier
            }
        }
        var url: URL {
            switch self {
            case .pinned(let app): app.url
            case .installed(let app): app.url
            }
        }
    }

    /// Every installed app (already alphabetical — see `AppDiscovery.apps`)
    /// by default, rather than the Dock's own pinned order — the "Épinglé"
    /// toggle is there for whoever wants that view back, but isn't the
    /// default the way real Windows 11 has it. Typing always searches
    /// every installed app regardless of the toggle's state.
    private var displayedApps: [DisplayApp] {
        if !state.query.isEmpty {
            return appDiscovery.apps
                .filter { $0.displayName.localizedCaseInsensitiveContains(state.query) }
                .map(DisplayApp.installed)
        }
        if state.windows11ShowPinnedOnly {
            return windowManager.pinnedApps.map(DisplayApp.pinned)
        }
        return appDiscovery.apps.map(DisplayApp.installed)
    }

    private var sectionTitle: String {
        if !state.query.isEmpty { return L("start.search_results") }
        return state.windows11ShowPinnedOnly ? L("start.pinned") : L("start.all_apps")
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollViewReader { proxy in
                ThemedScrollView(proxy: proxy, accentColor: Color(hex: tokens.colors.accent), itemIDs: displayedApps.map(\.id)) {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader
                        appGrid
                    }
                    .padding(20)
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    guard displayedApps.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(displayedApps[newIndex].id, anchor: .center)
                    }
                }
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
        guard displayedApps.indices.contains(state.selectedIndex) else { return }
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
        .background(SearchFieldBackground(tokens: tokens))
        .padding(16)
    }

    private var sectionHeader: some View {
        HStack {
            Text(sectionTitle)
                .font(.system(size: tokens.typography.fontSize, weight: .semibold))
            Spacer()
            if state.query.isEmpty {
                Button {
                    state.windows11ShowPinnedOnly.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Text(state.windows11ShowPinnedOnly ? L("start.all_apps") : L("start.pinned"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: tokens.typography.fontSize - 1))
                    .foregroundStyle(Color(hex: tokens.colors.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var appGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(Array(displayedApps.enumerated()), id: \.element.id) { index, app in
                appCell(app, isSelected: index == state.selectedIndex)
                    .id(app.id)
            }
        }
    }

    private func appCell(_ app: DisplayApp, isSelected: Bool) -> some View {
        Button {
            state.selectedIndex = displayedApps.firstIndex(where: { $0.id == app.id }) ?? state.selectedIndex
            launch(app)
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                Text(app.displayName)
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
        }
    }

    private func launch(_ app: DisplayApp) {
        switch app {
        case .pinned(let pinned):
            windowManager.launch(pinned)
        case .installed(let installed):
            LaunchHistoryStore.recordLaunch(bundleIdentifier: installed.bundleIdentifier)
            NSWorkspace.shared.openApplication(at: installed.url, configuration: NSWorkspace.OpenConfiguration())
        }
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
