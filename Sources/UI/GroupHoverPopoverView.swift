import SwiftUI

/// The hover window-list content for a grouped task button (2+ windows of
/// the same app) — a clickable list of titles, shown above the icon.
/// Rendered by `TaskbarView` at its own top level, positioned by hand via
/// `WindowManager.groupButtonFrames`, rather than as a SwiftUI `.popover`
/// attached to the button itself: a `.popover` there rendered stretched
/// across the whole bar instead of anchored to its own source view — this
/// app's panel is a non-activating, unusually-leveled `NSPanel`, the same
/// kind of window SwiftUI's built-in popover/outside-click handling
/// doesn't reliably cope with elsewhere in this app (see
/// `StartMenuState`'s own doc comment on the exact same issue).
struct GroupHoverPopoverView: View {
    let windows: [AppWindow]
    let tokens: ThemeTokens
    let windowManager: WindowManager
    let bundleIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(windows, id: \.id) { window in
                windowRow(window)
            }
        }
        .padding(6)
        .frame(minWidth: 220)
        .background(Color(hex: tokens.panel.backgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: tokens.taskButton.cornerRadius))
        .shadow(radius: 8)
        .onHover { hovering in
            windowManager.setGroupHovered(bundleIdentifier, hovering: hovering)
        }
    }

    // A click just activates the window (like the single-window taskbar
    // button); minimize/close used to be always-visible inline buttons,
    // but now need a right-click first, same as everywhere else — one
    // fewer thing competing for space/attention in a plain list of titles.
    private func windowRow(_ window: AppWindow) -> some View {
        HStack(spacing: 8) {
            if window.isMinimized {
                Circle()
                    .fill(Color(hex: tokens.colors.textSecondary))
                    .frame(width: 4, height: 4)
            }
            Text(window.title)
                .font(.system(size: tokens.typography.fontSize))
                .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(hex: tokens.colors.buttonBackgroundHover).opacity(0.001)) // keeps the whole row hit-testable
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture {
            windowManager.activateOrMinimize(window)
        }
        .contextMenu {
            Button(window.isMinimized ? L("window.restore") : L("window.minimize")) {
                windowManager.toggleMinimize(window)
            }
            Button(L("window.close")) {
                windowManager.close(window)
            }
        }
    }
}
