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
        // Every action this button's context menu could offer (unpin,
        // change icon, restore icon) only applies while editing — outside
        // that mode there's nothing to show, and attaching `.contextMenu`
        // with an empty builder still pops up a blank menu on right-click
        // rather than nothing at all. Only attaching the modifier itself
        // while editing is what actually suppresses the menu entirely for
        // an app that isn't open.
        if windowManager.isEditingIcons {
            content.contextMenu {
                Button(L("taskbar.unpin")) {
                    windowManager.unpin(url: app.url, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
                }
                Button(L("icon_edit.change")) {
                    windowManager.presentIconPicker(for: app.bundleIdentifier)
                }
                if windowManager.hasCustomIcon(bundleIdentifier: app.bundleIdentifier) {
                    Button(L("icon_edit.restore_original")) {
                        windowManager.restoreOriginalIcon(for: app.bundleIdentifier)
                    }
                }
            }
        } else {
            content
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
        .help(app.displayName)
        .taskReorderable(bundleIdentifier: app.bundleIdentifier, windowManager: windowManager) {
            windowManager.launch(app)
        }
        // Last: needs to sit on top of `.taskReorderable`'s own `.onDrop`
        // target to actually receive left-clicks — see
        // `IconPressGesture.swift`'s doc comment.
        .iconPressAndHold(windowManager: windowManager, bundleIdentifier: app.bundleIdentifier, onTap: onLaunch, blocksContextMenuWhenNotEditing: true) { isHovering in
            windowManager.hoveredWindowID = isHovering ? "launcher-\(app.id)" : (windowManager.hoveredWindowID == "launcher-\(app.id)" ? nil : windowManager.hoveredWindowID)
        }
    }
}
