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
    let onLaunch: () -> Void

    private var tokens: ThemeTokens { theme.tokens }
    private static let rowIconSize: CGFloat = 24
    private static let rightColumnWidth: CGFloat = 220
    private static let topCornerRadius: CGFloat = 10

    /// Unifies `PinnedApp` (the default pinned list) and `InstalledApp`
    /// ("All Programs"/search results) so one row renderer handles either —
    /// same reasoning as `Windows11StartMenuView.DisplayApp`.
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

    private var displayedApps: [DisplayApp] {
        if !state.query.isEmpty {
            return appDiscovery.apps
                .filter { $0.displayName.localizedCaseInsensitiveContains(state.query) }
                .map(DisplayApp.installed)
        }
        if state.windows7ShowPinnedOnly {
            return windowManager.pinnedApps.map(DisplayApp.pinned)
        }
        // Every installed app, most-recently-launched-through-this-app
        // first — apps never launched this way keep `AppDiscovery`'s own
        // alphabetical order, after all the ones that do have a
        // timestamp.
        return appDiscovery.apps
            .map { (app: $0, timestamp: LaunchHistoryStore.lastLaunchTimestamp(bundleIdentifier: $0.bundleIdentifier)) }
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.timestamp, rhs.element.timestamp) {
                case (let l?, let r?): return l > r
                case (nil, nil): return lhs.offset < rhs.offset
                case (.some, nil): return true
                case (nil, .some): return false
                }
            }
            .map { DisplayApp.installed($0.element.app) }
    }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
            rightColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground(tokens: tokens, liquidGlassEnabled: liquidGlassEnabled, liquidGlassIntensity: liquidGlassIntensity, showTopBorder: false))
        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.topCornerRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: Self.topCornerRadius))
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
        guard displayedApps.indices.contains(state.selectedIndex) else { return }
        launch(displayedApps[state.selectedIndex])
    }

    // MARK: - Left column: programs + search

    private var leftColumn: some View {
        VStack(spacing: 0) {
            if state.query.isEmpty {
                headerRow
            }
            ScrollViewReader { proxy in
                ThemedScrollView(proxy: proxy, accentColor: Color(hex: tokens.colors.accent), itemIDs: displayedApps.map(\.id)) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(displayedApps.enumerated()), id: \.element.id) { index, app in
                            programRow(app, isSelected: index == state.selectedIndex)
                                .id(app.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    guard displayedApps.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(displayedApps[newIndex].id, anchor: .center)
                    }
                }
            }
            Divider()
            searchField
        }
        .frame(maxWidth: .infinity)
    }

    private var headerRow: some View {
        HStack {
            Text(state.windows7ShowPinnedOnly ? L("start.pinned") : L("start.all_programs"))
                .font(.system(size: tokens.typography.fontSize, weight: .semibold))
            Spacer()
            Button {
                state.windows7ShowPinnedOnly.toggle()
            } label: {
                Text(state.windows7ShowPinnedOnly ? L("start.all_apps") : L("start.pinned"))
                    .font(.system(size: tokens.typography.fontSize - 1))
                    .foregroundStyle(Color(hex: tokens.colors.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func programRow(_ app: DisplayApp, isSelected: Bool) -> some View {
        Button {
            state.selectedIndex = displayedApps.firstIndex(where: { $0.id == app.id }) ?? state.selectedIndex
            launch(app)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                    .resizable()
                    .frame(width: Self.rowIconSize, height: Self.rowIconSize)
                Text(app.displayName)
                    .font(.system(size: tokens.typography.fontSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color(hex: tokens.colors.buttonBackgroundActive).opacity(0.3) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color(hex: tokens.colors.accent), lineWidth: isSelected ? 2 : 0)
        )
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
        case .pinned(let pinned): windowManager.launch(pinned)
        case .installed(let installed):
            LaunchHistoryStore.recordLaunch(bundleIdentifier: installed.bundleIdentifier)
            NSWorkspace.shared.openApplication(at: installed.url, configuration: NSWorkspace.OpenConfiguration())
        }
        onLaunch()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            ThemeIcon(url: theme.iconURL("search"), colorHex: tokens.colors.textSecondary, size: 13)
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: NSColor(Color(hex: tokens.colors.textPrimary)),
                accentColor: NSColor(Color(hex: tokens.colors.accent)),
                fontSize: tokens.typography.fontSize,
                onNavigate: { direction in moveSelection(direction) },
                onSubmit: launchSelected
            )
            .frame(height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(SearchFieldBackground(tokens: tokens, cornerRadius: 6))
        .padding(.horizontal, 8)
    }

    // MARK: - Right column: account + quick links + shut down

    private var rightColumn: some View {
        VStack(spacing: 0) {
            accountHeader
            ScrollView {
                VStack(spacing: 2) {
                    quickLinkRow(icon: "doc.text", label: L("start.documents")) { open(.documents) }
                    quickLinkRow(icon: "photo", label: L("start.pictures")) { open(.pictures) }
                    quickLinkRow(icon: "music.note", label: L("start.music")) { open(.music) }
                    quickLinkRow(icon: "arrow.down.circle", label: L("start.downloads")) { open(.downloads) }
                    Divider().padding(.vertical, 4)
                    quickLinkRow(icon: "desktopcomputer", label: L("start.computer")) { open(.home) }
                    quickLinkRow(icon: "gearshape", label: L("start.control_panel"), action: openSystemSettings)
                    quickLinkRow(icon: "trash", label: L("app.trash")) { open(.trash) }
                }
                .padding(10)
            }
            Spacer(minLength: 0)
            Divider()
            shutDownRow
        }
        .frame(width: Self.rightColumnWidth)
        .background(Color(hex: tokens.colors.buttonBackground).opacity(0.35))
    }

    private var accountHeader: some View {
        VStack(spacing: 6) {
            Button(action: AppleAccountSettings.open) {
                Group {
                    if let photo = AccountPhoto.current() {
                        Image(nsImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        // No account picture set (or it couldn't be read) —
                        // falls back to a plain placeholder instead of an
                        // empty gap.
                        Image(systemName: "person.crop.square.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                            .frame(width: 56, height: 56)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: tokens.colors.textSecondary).opacity(0.4)))
            }
            .buttonStyle(.plain)
            .help(L("account.open_settings"))
            Text(NSFullUserName())
                .font(.system(size: tokens.typography.fontSize, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func quickLinkRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: tokens.typography.fontSize - 1))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(hex: tokens.colors.textPrimary))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private enum QuickFolder { case documents, pictures, music, downloads, home, trash }

    private func open(_ folder: QuickFolder) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url: URL
        switch folder {
        case .documents: url = home.appendingPathComponent("Documents")
        case .pictures: url = home.appendingPathComponent("Pictures")
        case .music: url = home.appendingPathComponent("Music")
        case .downloads: url = home.appendingPathComponent("Downloads")
        case .home: url = home
        case .trash: url = home.appendingPathComponent(".Trash")
        }
        NSWorkspace.shared.open(url)
        onLaunch()
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
        onLaunch()
    }

    private var shutDownRow: some View {
        HStack(spacing: 0) {
            Button(action: SessionManager.shutDown) {
                Text(L("session.shutdown"))
                    .font(.system(size: tokens.typography.fontSize, weight: .medium))
                    .foregroundStyle(Color(hex: tokens.colors.accentText))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            NativeMenuButton(systemImage: "chevron.up", size: 10, tintColor: Color(hex: tokens.colors.accentText), makeMenu: sessionMenu)
                .frame(width: 28)
        }
        .background(Color(hex: tokens.colors.buttonBackgroundActive).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(8)
    }

    private func sessionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L("session.lock"), handler: SessionManager.lockScreen))
        menu.addItem(ClosureMenuItem(title: L("session.sleep"), handler: SessionManager.sleep))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("session.logout"), handler: SessionManager.logOut))
        menu.addItem(ClosureMenuItem(title: L("session.restart"), handler: SessionManager.restart))
        return menu
    }
}
