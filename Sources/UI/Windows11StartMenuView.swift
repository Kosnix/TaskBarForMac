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
    private var iconSize: CGFloat { max(12, tokens.panel.height - 16) * 2 }

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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader
                    appGrid
                }
                .padding(20)
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
    }

    private static let topCornerRadius: CGFloat = 10

    private var searchField: some View {
        HStack(spacing: 8) {
            ThemeIcon(url: theme.iconURL("search"), colorHex: tokens.colors.textSecondary, size: 14)
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: NSColor(Color(hex: tokens.colors.textPrimary)),
                fontSize: tokens.typography.fontSize,
                onNavigate: nil,
                onSubmit: launchFirstResult
            )
            .frame(height: 20)
        }
        .padding(10)
        // A flat `buttonBackground` fill read as plain, unthemed grey in
        // most themes (that token is a neutral, not an expressive color) —
        // layering a light wash of the theme's own accent color on top
        // makes it visibly "this theme's" search field instead.
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: tokens.colors.buttonBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).fill(Color(hex: tokens.colors.accent).opacity(0.18)))
        )
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
            ForEach(displayedApps) { app in
                appCell(app)
            }
        }
    }

    private func appCell(_ app: DisplayApp) -> some View {
        Button {
            launch(app)
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                Text(app.displayName)
                    .font(.system(size: tokens.typography.fontSize - 1))
                    .lineLimit(1)
                    .frame(width: iconSize + 20)
            }
            .padding(6)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
            NSWorkspace.shared.openApplication(at: installed.url, configuration: NSWorkspace.OpenConfiguration())
        }
        onLaunch()
    }

    private func launchFirstResult() {
        guard let first = displayedApps.first else { return }
        launch(first)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20))
                Text(NSFullUserName())
                    .font(.system(size: tokens.typography.fontSize))
            }
            Spacer()
            Menu {
                Button(L("session.lock"), action: SessionManager.lockScreen)
                Button(L("session.sleep"), action: SessionManager.sleep)
                Divider()
                Button(L("session.logout"), action: SessionManager.logOut)
                Button(L("session.restart"), action: SessionManager.restart)
                Button(L("session.shutdown"), action: SessionManager.shutDown)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(12)
    }
}
