import AppKit
import SwiftUI

/// macOS's own (now-retired) Launchpad: every installed app in a paginated,
/// full-screen grid over a blurred/dimmed desktop, with type-to-search at
/// the top, folders, and drag-to-reorder (including across pages) — the
/// same core feature set the real thing had. The only start menu style
/// that isn't hosted in the small, anchored `StartMenuPanel` frame — see
/// `StartMenuPanel.frame(themeStore:)`'s full-screen special case for this
/// style, and `ShortcutsManager`'s Escape handling for how it closes
/// (there's no "outside" to click when the menu already covers the whole
/// screen).
///
/// Every tap, long-press, and drag interaction here goes through the raw
/// AppKit views in `LaunchpadIconGesture.swift` — see that file's own doc
/// comment for why (in short: SwiftUI's own `.onDrag`/`.onLongPressGesture`
/// combination was tried here first and turned out unusable, the same
/// gesture-composition conflict this project had already hit once before
/// for the taskbar's own icons).
struct LaunchpadStartMenuView: View {
    let appDiscovery: AppDiscovery
    let windowManager: WindowManager
    let theme: Theme
    let state: StartMenuState
    let onLaunch: () -> Void

    /// The real thing's own classic grid — 7 columns by 5 rows per page,
    /// regardless of screen size. What does follow the screen is how big
    /// the icons are and how far apart (see `Metrics`).
    private static let columns = 7
    private static let rows = 5

    /// Icon size and spacing, fitted to the screen the menu covers: the
    /// grid always fills the space between the search field and the page
    /// dots, so a small laptop display gets smaller, tighter icons (nothing
    /// cut off) and a big monitor gets larger, more spread-out ones.
    private struct Metrics {
        let iconSize: CGFloat
        let rowSpacing: CGFloat
        let columnSpacing: CGFloat
        /// Widest the grid is allowed to get — past it the columns would
        /// drift much further apart than the rows.
        let gridWidth: CGFloat

        /// Fixed chrome around the grid (see `body`): top padding, search
        /// field, its spacing, page dots with their spacing, bottom padding.
        private static let verticalChrome: CGFloat = 215
        private static let horizontalInset: CGFloat = 160
        /// What a cell adds around its icon: the label, its spacing, and
        /// the cell's own padding.
        private static let cellExtraHeight: CGFloat = 39
        private static let cellExtraWidth: CGFloat = 16
        private static let minGap: CGFloat = 14

        init(screenSize: CGSize) {
            let availableHeight = screenSize.height - Self.verticalChrome
            let availableWidth = screenSize.width - Self.horizontalInset
            let rows = CGFloat(LaunchpadStartMenuView.rows)
            let columns = CGFloat(LaunchpadStartMenuView.columns)

            let fitHeight = (availableHeight - (rows - 1) * Self.minGap) / rows - Self.cellExtraHeight
            let fitWidth = (availableWidth - (columns - 1) * Self.minGap) / columns - Self.cellExtraWidth
            iconSize = min(max(min(fitHeight, fitWidth), 48), 128)

            let cellHeight = iconSize + Self.cellExtraHeight
            rowSpacing = min(max((availableHeight - rows * cellHeight) / (rows - 1), Self.minGap), 72)
            columnSpacing = max(rowSpacing * 1.5, Self.minGap)
            gridWidth = min(availableWidth, columns * (iconSize + Self.cellExtraWidth) + (columns - 1) * columnSpacing)
        }
    }

    private var metrics: Metrics {
        Metrics(screenSize: DockController.dockScreen?.frame.size ?? CGSize(width: 1440, height: 900))
    }

    /// A drop point within this many points of a target cell's own center
    /// counts as "directly on it" (create/join a folder) rather than
    /// "nearby" (reorder) — deliberately smaller than a cell's own footprint,
    /// so only a drop that's genuinely centered on another icon merges, not
    /// one that's merely closer to it than to its other neighbors.
    private static let folderDropRadius: CGFloat = 28

    private var perPage: Int { Self.columns * Self.rows }
    private var isSearching: Bool { !state.query.isEmpty }

    /// Re-reads `LaunchpadOrderStore` fresh — bumping `launchpadOrderVersion`
    /// (see every `mutate(_:)` call below) is what tells SwiftUI this needs
    /// re-evaluating, the same role `WindowManager.iconOverrideVersion`
    /// plays for custom icons.
    private var allItems: [LaunchpadItem] {
        _ = state.launchpadOrderVersion
        return LaunchpadOrderStore.resolve(installedApps: appDiscovery.apps)
    }

    /// What actually renders: the live drag preview while one's in
    /// progress, otherwise the real, persisted order — same "preview vs.
    /// real" split `WindowManager.pendingIconOrder` uses for the taskbar's
    /// own reordering.
    private var effectiveItems: [LaunchpadItem] {
        state.launchpadPendingOrder ?? allItems
    }

    private var appsByID: [String: InstalledApp] {
        Dictionary(uniqueKeysWithValues: appDiscovery.apps.map { ($0.id, $0) })
    }

    private var searchResults: [InstalledApp] {
        appDiscovery.apps.filter {
            windowManager.matchesSearch(bundleIdentifier: $0.bundleIdentifier, realName: $0.displayName, query: state.query)
        }
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(effectiveItems.count) / Double(perPage))))
    }

    private func items(onPage page: Int) -> [LaunchpadItem] {
        let start = page * perPage
        guard start < effectiveItems.count else { return [] }
        return Array(effectiveItems[start..<min(start + perPage, effectiveItems.count)])
    }

    private var openFolder: (id: String, name: String, appIDs: [String])? {
        guard let id = state.openLaunchpadFolderID,
              case .folder(let id, let name, let appIDs) = allItems.first(where: { $0.id == id }) else { return nil }
        return (id, name, appIDs)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: metrics.columnSpacing), count: Self.columns)
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 28) {
                header
                    .padding(.horizontal, 80)
                Group {
                    if isSearching {
                        searchGrid
                            .frame(maxWidth: metrics.gridWidth)
                    } else {
                        // Not horizontally padded here, unlike every other
                        // piece of this screen — `pagedGrid` needs the
                        // *true* full screen width so its own `.clipped()`
                        // lines up with the real edge of the display. Each
                        // page's own content keeps the same 80pt inset
                        // applied internally instead (see `pagedGrid`), so
                        // icons still sit exactly where they did before;
                        // only where the slide itself gets cut off moves.
                        // Padding this the same way as everything else put
                        // that clip boundary 80pt inside the screen, so a
                        // page sliding in visibly popped into existence at
                        // a hard edge floating over the blurred desktop,
                        // instead of entering from genuinely off-screen the
                        // way real Launchpad/iOS do.
                        // Only here, never over `searchGrid`: the pager is
                        // an overlay that claims vertical wheel events, which
                        // would stop the search results from scrolling.
                        pagedGrid
                            .launchpadScrollPager(onPageChange: flipPage)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !isSearching && pageCount > 1 {
                    pageDots
                }
            }
            .padding(.top, 64)
            .padding(.bottom, 40)

            if !isSearching {
                edgeHoverZones
            }

            if let openFolder {
                folderOverlay(id: openFolder.id, name: openFolder.name, appIDs: openFolder.appIDs)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            state.launchpadPage = 0
        }
    }

    // MARK: - Background

    /// Real Launchpad's own look: the desktop itself, heavily blurred and
    /// dimmed — not this app's usual small-panel `PanelBackground`/Liquid
    /// Glass materials, which were never designed to cover a whole screen.
    private var background: some View {
        ZStack {
            VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow)
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        // Doubles as the lowest-priority drop target: a drag released
        // anywhere that isn't a specific cell (empty desktop space, the
        // header, a gap between icons) lands here — any real cell's own
        // drop handling above it in the z-order claims the event first, so
        // this only ever sees the leftovers. Its job is just making sure a
        // drag always ends in a clean, committed state no matter where it's
        // released.
        .launchpadScrim(
            onTap: {
                // Tapping empty space backs out one level at a time — stop
                // jiggling first, then close a folder, then close the menu —
                // same "undo the most recent mode first" precedence Escape
                // uses (see `ShortcutsManager`).
                if state.isEditingLaunchpad {
                    state.isEditingLaunchpad = false
                } else if state.openLaunchpadFolderID != nil {
                    withAnimation(.easeOut(duration: 0.2)) {
                        state.openLaunchpadFolderID = nil
                    }
                } else {
                    onLaunch()
                }
            },
            onDrop: commitDrag
        )
    }

    // MARK: - Header: search + Done

    private var header: some View {
        HStack {
            Spacer()
            searchField
            Spacer()
        }
        .overlay(alignment: .trailing) {
            if state.isEditingLaunchpad {
                Button(L("icon_edit.done")) {
                    state.isEditingLaunchpad = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            ThemeIcon(url: theme.iconURL("search"), colorHex: "#FFFFFF", size: 16)
            AutoFocusTextField(
                placeholder: L("search.placeholder"),
                text: Binding(get: { state.query }, set: { state.query = $0 }),
                textColor: .white,
                accentColor: NSColor(Color(hex: theme.tokens.colors.accent)),
                fontSize: 16,
                onNavigate: { direction in moveSelection(direction) },
                onSubmit: launchFirstMatch
            )
            .frame(height: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15)))
    }

    private func launchFirstMatch() {
        guard let first = searchResults.first else { return }
        launch(first)
    }

    private func moveSelection(_ direction: TextFieldNavigation) {
        guard !isSearching else { return }
        switch direction {
        case .left: flipPage(.previous)
        case .right: flipPage(.next)
        case .up, .down: break
        }
    }

    // MARK: - Grids

    /// A real, native paging scroll view — each page gets a container-
    /// width slot laid out side by side, with `.scrollTargetBehavior(.paging)`
    /// driving both the live tracking *and* the settle. Two hand-rolled
    /// versions came before this one: the first swapped the entire grid's
    /// view identity per page (via `.id(state.launchpadPage)` + its own
    /// `.move` transition), which made every one of its up to 35 icons
    /// tear down and rebuild on each page change, firing their own
    /// `cell(for:)` pop transition at the same moment the page itself was
    /// sliding — two unrelated animations stacked on the same icons, which
    /// is what actually read as "buggy". The second kept one stable grid
    /// per page and drove the slide with a hand-computed `.offset`, bound
    /// to a fixed-duration `withAnimation` — correct for *programmatic*
    /// paging (page dots, dragging an icon to the edge), but it couldn't
    /// track a trackpad swipe's own live finger movement the way this
    /// does, only play a canned animation after the fact once some
    /// threshold was crossed, which read as rigid next to how every other
    /// paginated surface on macOS actually feels. Letting a real
    /// `ScrollView` own the gesture is what real 1:1 tracking + inertia-
    /// aware settling actually takes — both of those are what `ScrollView`
    /// already does for scrolling in general, `.paging` just adds "stop at
    /// the nearest page boundary" on top.
    ///
    /// Only pages in `renderedPages` actually build a `LazyVGrid` of real
    /// icons — everywhere else is a bare `Color.clear` taking up the same
    /// slot, so a Launchpad with several pages isn't paying to keep every
    /// page's icons alive at once. Always current ± 1: a live trackpad
    /// drag can only ever reach an adjacent page before it either commits
    /// or springs back, so that's the one window guaranteed to cover it,
    /// computed fresh off `state.launchpadPage` rather than tracked by
    /// hand — nothing drives the scroll view's own gesture through this
    /// code at all, so there's no single call site left to update it from.
    private var renderedPages: Set<Int> {
        Set((state.launchpadPage - 1)...(state.launchpadPage + 1)).filter { (0..<pageCount).contains($0) }
    }

    private var pagedGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { page in
                    Group {
                        if renderedPages.contains(page) {
                            LazyVGrid(columns: gridColumns, spacing: metrics.rowSpacing) {
                                ForEach(items(onPage: page)) { item in
                                    cell(for: item)
                                }
                            }
                            // Centered at the grid's own width rather than
                            // inset from `body`: the slide itself needs the
                            // true, unpadded screen width to clip against
                            // (see `body`'s own comment on `pagedGrid`).
                            .frame(maxWidth: metrics.gridWidth)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .containerRelativeFrame(.horizontal)
                    .id(page)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding(
            get: { Optional(state.launchpadPage) },
            set: { newPage in
                guard let newPage else { return }
                state.launchpadPage = newPage
            }
        ))
        // `.never`, not `.hidden` — `.hidden` still lets a scroller flash
        // back in during an active scroll on macOS when the system's own
        // "show scroll bars: always" preference is set; `.never` is the
        // stronger guarantee that it stays off regardless.
        .scrollIndicators(.never)
        .scrollDisabled(isSearching)
    }

    private var searchGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: metrics.rowSpacing) {
                ForEach(searchResults) { app in
                    VStack(spacing: 8) {
                        Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                            .resizable()
                            .frame(width: metrics.iconSize, height: metrics.iconSize)
                        Text(displayName(for: app))
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                    .onTapGesture { launch(app) }
                    .contextMenu { appContextMenu(app, folderID: nil) }
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// Two thin strips sitting in the screen's own outer margin (outside
    /// the grid's own padded content area, so they never overlap an actual
    /// icon), only hit-testable while a drag is in progress — dragging into
    /// one and lingering flips to the adjacent page, exactly like the edge
    /// of real Launchpad's own grid.
    private var edgeHoverZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 80)
                .launchpadEdgeZone(
                    onHoverStart: { scheduleEdgeFlip(.previous) },
                    onHoverEnd: cancelEdgeFlip,
                    onDrop: commitDrag
                )
            Spacer()
            Color.clear
                .frame(width: 80)
                .launchpadEdgeZone(
                    onHoverStart: { scheduleEdgeFlip(.next) },
                    onHoverEnd: cancelEdgeFlip,
                    onDrop: commitDrag
                )
        }
        .allowsHitTesting(state.launchpadDragItemID != nil)
    }

    @ViewBuilder
    private func cell(for item: LaunchpadItem) -> some View {
        Group {
            switch item {
            case .app(let id):
                if let app = appsByID[id] {
                    appCell(app)
                }
            case .folder(let id, let name, let appIDs):
                folderCell(id: id, name: name, appIDs: appIDs)
            }
        }
        // Every appearance/disappearance in the grid — a new app being
        // discovered, a folder created or dissolved, an icon pulled back
        // out of one — gets the same pop the taskbar's own icons use
        // (`TaskbarView.taskbarAppearance`), instead of just snapping in.
        .transition(.scale(scale: 0.4).combined(with: .opacity))
    }

    private func appCell(_ app: InstalledApp) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                .resizable()
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .wiggle(isActive: state.isEditingLaunchpad, seed: app.id.hashValue)
            Text(displayName(for: app))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(8)
        .contentShape(Rectangle())
        .opacity(state.launchpadDragItemID == app.id ? 0.35 : 1)
        .scaleEffect(state.launchpadMergeTargetID == app.id ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.15), value: state.launchpadMergeTargetID)
        .launchpadCellGesture(
            itemID: app.id,
            onTap: {
                guard !state.isEditingLaunchpad else { return }
                launch(app)
            },
            onLongPress: { state.isEditingLaunchpad = true },
            dragImageProvider: { windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon },
            onDragWillBegin: {
                state.launchpadDragItemID = app.id
            },
            onDragEnded: resetDragState,
            onDropUpdate: { point, size in updateDropTarget(targetID: app.id, point: point, size: size) },
            onDropExit: { clearMergeTargetIfNeeded(app.id) },
            onPerformDrop: { _, _ in performDrop(targetID: app.id) }
        )
        .contextMenu { appContextMenu(app, folderID: nil) }
    }

    private func folderCell(id: String, name: String, appIDs: [String]) -> some View {
        VStack(spacing: 8) {
            folderIcon(appIDs: appIDs)
                .wiggle(isActive: state.isEditingLaunchpad, seed: id.hashValue)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(8)
        .contentShape(Rectangle())
        .opacity(state.launchpadDragItemID == id ? 0.35 : 1)
        .scaleEffect(state.launchpadMergeTargetID == id ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.15), value: state.launchpadMergeTargetID)
        .launchpadCellGesture(
            itemID: id,
            onTap: {
                // Unlike an app icon, a folder still opens while jiggling —
                // real Launchpad lets you rearrange or remove a folder's
                // own apps without leaving edit mode first, so tapping it
                // needs to work the whole time, not just before entering it.
                withAnimation(.easeOut(duration: 0.2)) {
                    state.openLaunchpadFolderID = id
                }
            },
            onLongPress: { state.isEditingLaunchpad = true },
            dragImageProvider: { Self.renderedImage(of: folderIcon(appIDs: appIDs), size: NSSize(width: metrics.iconSize, height: metrics.iconSize)) },
            onDragWillBegin: {
                state.launchpadDragItemID = id
            },
            onDragEnded: resetDragState,
            onDropUpdate: { point, size in updateDropTarget(targetID: id, point: point, size: size) },
            onDropExit: { clearMergeTargetIfNeeded(id) },
            onPerformDrop: { _, _ in performDrop(targetID: id) }
        )
    }

    private func folderIcon(appIDs: [String]) -> some View {
        let previewApps = appIDs.prefix(4).compactMap { appsByID[$0] }
        return RoundedRectangle(cornerRadius: metrics.iconSize * 0.23)
            .fill(Color.white.opacity(0.18))
            .frame(width: metrics.iconSize, height: metrics.iconSize)
            .overlay(
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    ForEach(previewApps, id: \.id) { app in
                        Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(12)
            )
    }

    /// Renders an arbitrary SwiftUI view to a plain `NSImage` — used only
    /// for the folder drag image, since a folder (unlike an app) has no
    /// single icon file of its own to hand to `NSDraggingItem` directly.
    @MainActor
    private static func renderedImage(of content: some View, size: NSSize) -> NSImage? {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    @ViewBuilder
    private func appContextMenu(_ app: InstalledApp, folderID: String?) -> some View {
        Button(windowManager.isPinned(bundleIdentifier: app.bundleIdentifier) ? L("taskbar.unpin") : L("taskbar.pin")) {
            windowManager.isPinned(bundleIdentifier: app.bundleIdentifier)
                ? windowManager.unpin(url: app.url, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
                : windowManager.pin(url: app.url, displayName: app.displayName)
        }
        if let folderID {
            Button(L("menu.remove_from_folder")) {
                mutate { LaunchpadOrderStore.removingFromFolder($0, appID: app.id, folderID: folderID) }
            }
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

    private func displayName(for app: InstalledApp) -> String {
        windowManager.resolvedDisplayName(bundleIdentifier: app.bundleIdentifier, fallback: app.displayName)
    }

    // MARK: - Folder overlay

    private func folderOverlay(id: String, name: String, appIDs: [String]) -> some View {
        let apps = appIDs.compactMap { appsByID[$0] }
        return ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                // No `onDrop` here (unlike the main background's own
                // scrim): a drag on one of this folder's own apps closes
                // the folder the instant it starts (see `folderAppCell`'s
                // `onDragWillBegin`), so this scrim never actually exists
                // for the rest of a drag to be dropped on — only its tap,
                // for closing the folder normally, still applies.
                .launchpadScrim(
                    onTap: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            state.openLaunchpadFolderID = nil
                        }
                    },
                    onDrop: {}
                )

            VStack(spacing: 24) {
                TextField(
                    "",
                    text: Binding(
                        get: { name },
                        set: { newName in mutate(animated: false) { LaunchpadOrderStore.renaming($0, folderID: id, name: newName) } }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(width: 300)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: min(5, max(1, apps.count))), spacing: 28) {
                    ForEach(apps) { app in
                        folderAppCell(app, folderID: id)
                    }
                }
            }
            .padding(40)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial))
        }
    }

    /// An app inside an open folder — tappable like any other icon, and
    /// draggable to be pulled back out onto the main grid. Unlike the
    /// folder's own exit scrim (the old "drop anywhere outside the card"
    /// fallback), this now closes the folder and seeds the live reorder
    /// preview the *instant* the drag starts, not only once it's dropped:
    /// that reveals the main grid immediately, so the rest of the drag
    /// plays out exactly like an ordinary main-grid drag — hovering a cell
    /// previews exactly where the pulled-out app will land (or merges it
    /// into a folder there), the same live feedback every other drag in
    /// this grid already gives, instead of the app just vanishing until
    /// it's dropped somewhere.
    private func folderAppCell(_ app: InstalledApp, folderID: String) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                .resizable()
                .frame(width: metrics.iconSize * 0.72, height: metrics.iconSize * 0.72)
                .wiggle(isActive: state.isEditingLaunchpad, seed: app.id.hashValue)
            Text(displayName(for: app))
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .opacity(state.launchpadDragItemID == app.id ? 0.35 : 1)
        .launchpadCellGesture(
            itemID: app.id,
            onTap: {
                guard !state.isEditingLaunchpad else { return }
                launch(app)
            },
            onLongPress: { state.isEditingLaunchpad = true },
            dragImageProvider: { windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon },
            onDragWillBegin: {
                state.launchpadDragItemID = app.id
                // Pre-seed the preview with the app already pulled out
                // (appended at the very end, same as a plain drop with no
                // specific target) — `updateDropTarget`/`performDrop` for
                // every main-grid cell already just read/write
                // `launchpadPendingOrder`, so from here on this behaves
                // exactly like a drag that started on the main grid itself.
                state.launchpadPendingOrder = LaunchpadOrderStore.removingFromFolder(allItems, appID: app.id, folderID: folderID)
                withAnimation(.easeOut(duration: 0.2)) {
                    state.openLaunchpadFolderID = nil
                }
            },
            onDragEnded: resetDragState
        )
        .contextMenu { appContextMenu(app, folderID: folderID) }
    }

    // MARK: - Page dots

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { page in
                Circle()
                    .fill(Color.white.opacity(page == state.launchpadPage ? 0.9 : 0.35))
                    .frame(width: 7, height: 7)
                    .onTapGesture { goToPage(page) }
            }
        }
    }

    // MARK: - Actions

    private func launch(_ app: InstalledApp) {
        LaunchHistoryStore.recordLaunch(bundleIdentifier: app.bundleIdentifier)
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        onLaunch()
    }

    private func flipPage(_ edge: LaunchpadEdge) {
        switch edge {
        case .previous: goToPage(max(0, state.launchpadPage - 1))
        case .next: goToPage(min(pageCount - 1, state.launchpadPage + 1))
        }
    }

    /// The one place `state.launchpadPage` changes *programmatically*
    /// (page dots, an icon dragged to the edge, arrow keys) — `pagedGrid`'s
    /// own `.scrollPosition(id:)` binding reads it directly and scrolls
    /// there, so wrapping this in `withAnimation` is all that's needed. A
    /// live trackpad swipe bypasses this entirely: it drives the scroll
    /// view's own gesture directly, which writes back to
    /// `state.launchpadPage` through that same binding once it settles.
    private func goToPage(_ page: Int) {
        guard page != state.launchpadPage, (0..<pageCount).contains(page) else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            state.launchpadPage = page
        }
    }

    private func scheduleEdgeFlip(_ edge: LaunchpadEdge) {
        state.launchpadEdgeHoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [self] in flipPage(edge) }
        state.launchpadEdgeHoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    private func cancelEdgeFlip() {
        state.launchpadEdgeHoverWorkItem?.cancel()
        state.launchpadEdgeHoverWorkItem = nil
    }

    // MARK: - Drag target math (shared by app and folder cells)

    /// Called continuously while another item's drag hovers over `targetID`
    /// — close to its own center previews a folder merge, anywhere else
    /// previews a reorder relative to it. `point`/`size` come straight from
    /// `LaunchpadCellView`'s own real, current bounds (see that class's doc
    /// comment) — no shared frame-tracking state needed anywhere.
    private func updateDropTarget(targetID: String, point: CGPoint, size: CGSize) {
        guard let draggedID = state.launchpadDragItemID, draggedID != targetID else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let distance = hypot(point.x - center.x, point.y - center.y)

        if distance <= Self.folderDropRadius {
            if state.launchpadMergeTargetID != targetID {
                state.launchpadMergeTargetID = targetID
            }
        } else {
            if state.launchpadMergeTargetID == targetID {
                state.launchpadMergeTargetID = nil
            }
            let insertBefore = point.x < center.x
            let base = state.launchpadPendingOrder ?? allItems
            let updated = LaunchpadOrderStore.reordering(base, draggedID: draggedID, targetID: targetID, insertBefore: insertBefore)
            if updated != base {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    state.launchpadPendingOrder = updated
                }
            }
        }
    }

    private func clearMergeTargetIfNeeded(_ targetID: String) {
        if state.launchpadMergeTargetID == targetID {
            state.launchpadMergeTargetID = nil
        }
    }

    private func performDrop(targetID: String) {
        guard let draggedID = state.launchpadDragItemID else { return }
        if state.launchpadMergeTargetID == targetID {
            mergeAndReset(draggedID: draggedID, targetID: targetID)
        } else {
            commitDrag()
        }
    }

    /// The live preview (`state.launchpadPendingOrder`) already *is* the
    /// final order by the time a drop commits it — this just persists
    /// whatever it ended up as, or does nothing if the drag never actually
    /// crossed into a new position. Also what every drop that isn't on a
    /// specific target (the background, an edge zone) falls back to.
    private func commitDrag() {
        if let pending = state.launchpadPendingOrder {
            LaunchpadOrderStore.write(pending)
            state.bumpLaunchpadOrderVersion()
        }
        resetDragState()
    }

    private func mergeAndReset(draggedID: String, targetID: String) {
        mutate { LaunchpadOrderStore.merging($0, draggedID: draggedID, targetID: targetID) }
        resetDragState()
    }

    private func resetDragState() {
        state.launchpadDragItemID = nil
        state.launchpadPendingOrder = nil
        state.launchpadMergeTargetID = nil
    }

    private func mutate(animated: Bool = true, _ transform: ([LaunchpadItem]) -> [LaunchpadItem]) {
        guard animated else {
            LaunchpadOrderStore.write(transform(allItems))
            state.bumpLaunchpadOrderVersion()
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            LaunchpadOrderStore.write(transform(allItems))
            state.bumpLaunchpadOrderVersion()
        }
    }
}
