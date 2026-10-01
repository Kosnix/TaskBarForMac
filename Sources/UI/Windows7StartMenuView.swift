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

    private func programRow(_ app: InstalledApp, isSelected: Bool) -> some View {
        let isHovered = state.hoveredRowID == app.id
        return Button {
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
                    ? LinearGradient(colors: [Color(hex: tokens.colors.accent).opacity(0.55), Color(hex: tokens.colors.accent).opacity(0.28)], startPoint: .top, endPoint: .bottom)
                    : isHovered
                        ? LinearGradient(colors: [Color(hex: tokens.colors.accent).opacity(0.25), Color(hex: tokens.colors.accent).opacity(0.1)], startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color(hex: tokens.colors.accent).opacity(isSelected ? 0.9 : (isHovered ? 0.5 : 0)), lineWidth: 1)
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
        // Without this, the HStack above only ever sizes to fit its own
        // content (icon + placeholder text) — no amount of padding on the
        // *outside* can push a edge that was never reaching the column's
        // true width in the first place. This is what actually makes the
        // field's background span the row, not just look roughly
        // full-width by coincidence.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(SearchFieldBackground(tokens: tokens, liquidGlassEnabled: liquidGlassEnabled, liquidGlassIntensity: liquidGlassIntensity, cornerRadius: 6))
        // Left matches the program list's own `.padding(6)` above (see
        // `leftColumn`). Right is flush (0), not also 6 — the list sits in
        // a plain `ScrollView` with no outer padding of its own, so its
        // scrollbar (hidden via `.scrollIndicators(.hidden)`, but still
        // occupying that edge) tracks the column's true trailing edge, not
        // the 6pt-inset one the *rows* happen to stop at. Matching the
        // field's own trailing edge to that same true edge is what lines
        // the two up.
        .padding(.leading, 6)
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
        // A vertical frosted-glass tint (a hint of accent up top, fading to
        // the plain button background) instead of a single flat color —
        // the real Aero sidebar's own subtle gradient, not just a tint.
        .background(
            LinearGradient(
                colors: [Color(hex: tokens.colors.accent).opacity(0.18), Color(hex: tokens.colors.buttonBackground).opacity(0.4)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(hex: tokens.colors.separator).opacity(0.5))
                .frame(width: 1)
        }
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
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
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
        let rowID = "quick-\(label)"
        let isHovered = state.hoveredRowID == rowID
        return Button(action: action) {
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
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: tokens.colors.accent).opacity(isHovered ? 0.18 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            state.hoveredRowID = hovering ? rowID : (state.hoveredRowID == rowID ? nil : state.hoveredRowID)
        }
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
                    .font(.system(size: tokens.typography.fontSize, weight: .semibold))
                    .foregroundStyle(Color(hex: tokens.colors.accentText))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            NativeMenuButton(systemImage: "chevron.up", size: 10, tintColor: Color(hex: tokens.colors.accentText), makeMenu: sessionMenu)
                .frame(width: 28)
        }
        // A glossy button, not a flat one — the real Aero "Shut down" pill
        // is a top-to-bottom gradient with a bright highlight right under
        // the top edge, same glass language as the selection highlight and
        // the sidebar tint above.
        .background(
            LinearGradient(
                colors: [Color(hex: tokens.colors.accent), Color(hex: tokens.colors.buttonBackgroundActive)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
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
