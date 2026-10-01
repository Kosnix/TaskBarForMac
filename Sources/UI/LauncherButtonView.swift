import SwiftUI

/// A Dock-pinned app that isn't currently running: click launches it —
/// exactly like an idle launcher in Plasma's unified Task Manager. Sized to
/// the same `width` as running-window buttons in the same row (passed down
/// from `TaskbarView`'s adaptive task list) so pinned-but-closed apps never
/// look narrower/wider than open ones sitting right next to them.
///
/// Deliberately not a `Button` — see `TaskButtonView` for why (its own
/// click recognizer fights `.draggable`'s drag recognizer).
struct LauncherButtonView: View {
    let app: PinnedApp
    let tokens: ThemeTokens
    let windowManager: WindowManager
    let width: CGFloat
    let onLaunch: () -> Void

    private var isHovered: Bool { windowManager.hoveredWindowID == "launcher-\(app.id)" }
    private var iconSize: CGFloat { tokens.taskbarIconSize }

    var body: some View {
        // Unpinning works outside edit mode too now — only the icon-editing
        // actions stay behind it. The menu is always attached (never
        // conditionally, the way it used to be) since there's always at
        // least "Unpin" to show now, sidestepping the empty-builder-still-
        // shows-a-blank-popup problem that made the old conditional
        // attachment necessary in the first place.
        content.contextMenu {
            Button(L("taskbar.unpin")) {
                windowManager.unpin(url: app.url, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
            }
            if windowManager.isEditingIcons {
                Button(L("icon_edit.change")) {
                    windowManager.presentIconPicker(for: app.bundleIdentifier)
                }
                if windowManager.hasCustomIcon(bundleIdentifier: app.bundleIdentifier) {
                    Button(L("icon_edit.restore_original")) {
                        windowManager.restoreOriginalIcon(for: app.bundleIdentifier)
                    }
                }
            }
        }
    }

    private var content: some View {
        // Icon only, always — "icon + name" only ever applies to actually
        // open windows; a pinned-but-closed launcher stays icon-only
        // regardless, matching how the real Dock never shows names either.
        HStack(spacing: 6) {
            Image(nsImage: windowManager.resolvedIcon(bundleIdentifier: app.bundleIdentifier, fallback: app.icon) ?? app.icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .wiggle(isActive: windowManager.isEditingIcons, seed: app.id.hashValue)
                .hoverLift(isHovered: isHovered, zoomRatio: tokens.effectiveTaskbarIconHoverZoom)
        }
        .padding(.horizontal, tokens.effectiveTaskbarEdgePadding)
        .frame(width: width, height: tokens.panel.height - 8, alignment: .leading)
        // No more `.clipShape` — see `TaskButtonView`'s identical removal.
        .contentShape(Rectangle())
        .help(windowManager.resolvedDisplayName(bundleIdentifier: app.bundleIdentifier, fallback: app.displayName))
        .taskReorderable(bundleIdentifier: app.bundleIdentifier, windowManager: windowManager) {
            windowManager.launch(app)
        }
        // Last: needs to sit on top of `.taskReorderable`'s own `.onDrop`
        // target to actually receive left-clicks — see
        // `IconPressGesture.swift`'s doc comment. `blocksContextMenuWhenNotEditing`
        // dropped — the context menu now always has at least "Unpin" to
        // show, so a right-click has somewhere to go outside edit mode too.
        .iconPressAndHold(windowManager: windowManager, bundleIdentifier: app.bundleIdentifier, onTap: onLaunch) { isHovering in
            windowManager.hoveredWindowID = isHovering ? "launcher-\(app.id)" : (windowManager.hoveredWindowID == "launcher-\(app.id)" ? nil : windowManager.hoveredWindowID)
        }
    }
}
