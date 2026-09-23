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
    private var iconSize: CGFloat { max(12, tokens.panel.height - 16) }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
            if width >= iconSize + 50 {
                Text(app.displayName)
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, tokens.spacing.edgePadding)
        .frame(width: width, height: tokens.panel.height - 8)
        .background(isHovered ? Color(hex: tokens.colors.accent).opacity(0.3) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: tokens.taskButton.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: onLaunch)
        .help(app.displayName)
        .onHover { isHovering in
            windowManager.hoveredWindowID = isHovering ? "launcher-\(app.id)" : (windowManager.hoveredWindowID == "launcher-\(app.id)" ? nil : windowManager.hoveredWindowID)
        }
        .contextMenu {
            Button(L("taskbar.unpin")) {
                windowManager.unpin(url: app.url, bundleIdentifier: app.bundleIdentifier)
            }
        }
        .taskReorderable(bundleIdentifier: app.bundleIdentifier, windowManager: windowManager) {
            windowManager.launch(app)
        }
    }
}
