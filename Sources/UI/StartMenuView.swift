import AppKit
import SwiftUI

/// Kickoff-style launcher: search field on top, categories (with real Breeze
/// category icons) down the left, matching applications in a grid on the
/// right. Arrow keys move a selection through the grid (auto-scrolling to
/// keep it visible) and Enter launches it; Left from the grid's first
/// column moves into the category list, where Up/Down browse categories and
/// Right/Enter jumps back into the grid — typing in the search field never
/// loses focus while doing any of this.
///
/// Filter/navigation state lives in the shared, injected `StartMenuState`
/// rather than view-local `@State`, so this view stays macro-free and
/// buildable without Xcode (see `ShortcutsManager`).
struct StartMenuView: View {
    let appDiscovery: AppDiscovery
    let windowManager: WindowManager
    let theme: Theme
    let state: StartMenuState
    let liquidGlassEnabled: Bool
    let liquidGlassIntensity: Double
    let onLaunch: () -> Void

    private var tokens: ThemeTokens { theme.tokens }
    /// Fixed, not `.adaptive`: an adaptive grid's real column count depends
    /// on whether the vertical scrollbar happens to be showing (fewer items
    /// than fit on screen vs. more), which made Up/Down's jump size
    /// inconsistent — a fixed count removes that ambiguity entirely.
    private static let columnCount = 3
    private let gridColumns = Array(repeating: GridItem(.flexible(minimum: 60), spacing: 8), count: StartMenuView.columnCount)
    private let gridPadding: CGFloat = 10

    /// `nil` (the "all applications" row) followed by every real category,
    /// in the same order the list renders them — indexed for Up/Down nav.
    private var categoryEntries: [String?] { [nil] + appDiscovery.categories }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            HStack(spacing: 0) {
                categoryList
                    .frame(width: 180)
                Divider()
                appGrid
            }
            Divider()
            sessionFooter
        }
        // Fills whatever size `StartMenuPanel` gives it — the panel itself
        // (not this view) owns the actual dimensions now, since it's a
        // real, user-resizable window rather than a fixed-size popover.
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

    /// Kickoff's "leave" row: session control for the current login session.
    private var sessionFooter: some View {
        HStack(spacing: 8) {
            Button(action: AppleAccountSettings.open) {
                Group {
                    if let photo = AccountPhoto.current() {
                        Image(nsImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                    } else {
                        ThemeIcon(url: theme.iconURL("start-button"), colorHex: tokens.colors.textSecondary, size: 20)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(L("account.open_settings"))
            Text(NSFullUserName())
                .font(.system(size: tokens.typography.fontSize))
                .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                .lineLimit(1)
            Spacer()
            sessionButton(icon: "session-lock", label: L("session.lock"), action: SessionManager.lockScreen)
            sessionButton(icon: "session-sleep", label: L("session.sleep"), action: SessionManager.sleep)
            sessionButton(icon: "session-logout", label: L("session.logout"), action: SessionManager.logOut)
            sessionButton(icon: "session-restart", label: L("session.restart"), action: SessionManager.restart)
            sessionButton(icon: "session-shutdown", label: L("session.shutdown"), action: SessionManager.shutDown)
        }
        .padding(8)
    }

    private func sessionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ThemeIcon(url: theme.iconURL(icon), colorHex: tokens.colors.textSecondary, size: 18)
                .padding(8)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            ThemeIcon(url: theme.iconURL("search"), colorHex: tokens.colors.textSecondary, size: 14)
            // Auto-focuses on appear, so typing works the instant the start
            // menu opens without clicking into the field first. Arrow keys
            // and Return are forwarded here instead of being consumed as
            // text editing commands.
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: NSColor(Color(hex: tokens.colors.textPrimary)),
                accentColor: NSColor(Color(hex: tokens.colors.accent)),
                fontSize: tokens.typography.fontSize,
                onNavigate: { direction in moveSelection(direction) },
                onSubmit: { confirmSelection() }
            )
            .frame(height: 20)
        }
        .padding(10)
        .background(SearchFieldBackground(tokens: tokens))
        .padding(10)
    }

    private func moveSelection(_ direction: TextFieldNavigation) {
        switch state.focusedRegion {
        case .categories:
            moveCategorySelection(direction)
        case .grid:
            moveGridSelection(direction)
        }
    }

    private func moveGridSelection(_ direction: TextFieldNavigation) {
        let count = filteredApps.count
        guard count > 0 else { return }
        let columns = Self.columnCount

        if direction == .left && state.selectedIndex % columns == 0 {
            // Leftmost column: hand off to the category list instead of
            // getting stuck at the edge.
            state.focusedRegion = .categories
            syncCategoryIndexFromSelection()
            return
        }

        var next = state.selectedIndex
        switch direction {
        case .up: next -= columns
        case .down: next += columns
        case .left: next -= 1
        case .right: next += 1
        }
        state.selectedIndex = min(max(0, next), count - 1)
    }

    private func moveCategorySelection(_ direction: TextFieldNavigation) {
        let entries = categoryEntries
        switch direction {
        case .up:
            state.selectedCategoryIndex = max(0, state.selectedCategoryIndex - 1)
            state.selectedCategory = entries[state.selectedCategoryIndex]
        case .down:
            state.selectedCategoryIndex = min(entries.count - 1, state.selectedCategoryIndex + 1)
            state.selectedCategory = entries[state.selectedCategoryIndex]
        case .right:
            state.focusedRegion = .grid
        case .left:
            break
        }
    }

    private func syncCategoryIndexFromSelection() {
        if let index = categoryEntries.firstIndex(where: { $0 == state.selectedCategory }) {
            state.selectedCategoryIndex = index
        }
    }

    private func confirmSelection() {
        switch state.focusedRegion {
        case .categories:
            state.focusedRegion = .grid
        case .grid:
            launchSelected()
        }
    }

    private func launchSelected() {
        let apps = filteredApps
        guard apps.indices.contains(state.selectedIndex) else { return }
        launch(apps[state.selectedIndex])
    }

    private var categoryList: some View {
        ScrollViewReader { proxy in
            ThemedScrollView(proxy: proxy, accentColor: Color(hex: tokens.colors.accent), itemIDs: ["cat-all"] + appDiscovery.categories.map { "cat-\($0)" }) {
                VStack(alignment: .leading, spacing: 2) {
                    categoryRow(title: L("category.all"), value: nil)
                        .id("cat-all")
                    ForEach(appDiscovery.categories, id: \.self) { category in
                        categoryRow(title: Localization.categoryDisplayName(for: category), value: category)
                            .id("cat-\(category)")
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selectedCategoryIndex) { _, _ in
                guard state.focusedRegion == .categories else { return }
                let entries = categoryEntries
                guard entries.indices.contains(state.selectedCategoryIndex) else { return }
                let id = entries[state.selectedCategoryIndex].map { "cat-\($0)" } ?? "cat-all"
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func categoryRow(title: String, value: String?) -> some View {
        let isSelected = state.selectedCategory == value
        let isKeyboardFocused = isSelected && state.focusedRegion == .categories
        let iconColor = isSelected ? tokens.colors.accentText : tokens.colors.textSecondary
        return Button {
            state.selectedCategory = value
            syncCategoryIndexFromSelection()
        } label: {
            HStack(spacing: 8) {
                ThemeIcon(url: theme.categoryIconURL(forCategoryLabel: value), colorHex: iconColor, size: 16)
                Text(title)
                    .font(.system(size: tokens.typography.fontSize))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color(hex: tokens.colors.buttonBackgroundActive) : Color.clear)
            .foregroundStyle(isSelected ? Color(hex: tokens.colors.accentText) : Color(hex: tokens.colors.textPrimary))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(hex: tokens.colors.accent), lineWidth: isKeyboardFocused ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    private var appGrid: some View {
        ScrollViewReader { proxy in
            ThemedScrollView(proxy: proxy, accentColor: Color(hex: tokens.colors.accent), itemIDs: filteredApps.map(\.id)) {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                        appCell(app, isSelected: index == state.selectedIndex && state.focusedRegion == .grid) {
                            state.focusedRegion = .grid
                            state.selectedIndex = index
                        }
                        .id(app.id)
                    }
                }
                .padding(gridPadding)
            }
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard state.focusedRegion == .grid, filteredApps.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(filteredApps[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private func appCell(_ app: InstalledApp, isSelected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button {
            onSelect()
            launch(app)
        } label: {
            VStack(spacing: 4) {
                // Same size as a taskbar app icon (`TaskButtonView.iconSize`
                // etc.), not a fixed per-theme constant — so resizing the
                // taskbar (and its icons) keeps everything matching.
                Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                    .resizable()
                    .frame(width: tokens.taskbarIconSize, height: tokens.taskbarIconSize)
                Text(app.displayName)
                    .font(.system(size: tokens.typography.fontSize - 1))
                    .lineLimit(1)
                    .frame(width: 84)
            }
            .padding(6)
            .background(isSelected ? Color(hex: tokens.colors.buttonBackgroundActive).opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(hex: tokens.colors.accent), lineWidth: isSelected ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(windowManager.isPinned(bundleIdentifier: app.bundleIdentifier) ? L("taskbar.unpin") : L("taskbar.pin")) {
                windowManager.isPinned(bundleIdentifier: app.bundleIdentifier)
                    ? windowManager.unpin(url: app.url, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
                    : windowManager.pin(url: app.url, displayName: app.displayName)
            }
            Divider()
            Button(L("app.trash")) {
                confirmUninstall(app)
            }
        }
    }

    private func confirmUninstall(_ app: InstalledApp) {
        let alert = NSAlert()
        alert.messageText = L("alert.trash_app.title", ["name": app.displayName])
        alert.informativeText = L("alert.trash_app.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("app.trash"))
        alert.addButton(withTitle: L("button.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            appDiscovery.uninstall(app)
        }
    }

    /// Most-recently-launched-through-this-app first (see
    /// `LaunchHistoryStore.sortedByRecency`) — same ordering every other
    /// start menu style uses now, instead of `AppDiscovery`'s plain
    /// alphabetical one.
    private var filteredApps: [InstalledApp] {
        let matching = appDiscovery.apps.filter { app in
            let matchesCategory = state.selectedCategory == nil || app.category == state.selectedCategory
            let matchesQuery = state.query.isEmpty || app.displayName.localizedCaseInsensitiveContains(state.query)
            return matchesCategory && matchesQuery
        }
        return LaunchHistoryStore.sortedByRecency(matching, bundleIdentifier: \.bundleIdentifier)
    }

    private func launch(_ app: InstalledApp) {
        LaunchHistoryStore.recordLaunch(bundleIdentifier: app.bundleIdentifier)
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        onLaunch()
    }
}
