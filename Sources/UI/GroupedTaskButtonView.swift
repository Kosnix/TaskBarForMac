import SwiftUI

/// An app with 2+ open windows: one icon in the bar, hovering shows a
/// clickable list of its windows (title + minimize/close) above the icon —
/// not full thumbnail previews (explicitly out of scope), just a list.
struct GroupedTaskButtonView: View {
    let bundleIdentifier: String
    let appName: String
    let appIcon: NSImage?
    let windows: [AppWindow]
    let tokens: ThemeTokens
    let windowManager: WindowManager
    let width: CGFloat

    private var iconSize: CGFloat { max(12, tokens.panel.height - 16) }
    private var isHovered: Bool { windowManager.hoveredGroupID == bundleIdentifier }
    private var anyActive: Bool { windows.contains { !$0.isMinimized } }
    /// `bundleIdentifier` falls back to a synthetic "pid-…" key when a
    /// window's real app has no bundle id — not something the Dock can pin,
    /// so dragging is only offered for a real one.
    private var realBundleIdentifier: String? { bundleIdentifier.hasPrefix("pid-") ? nil : bundleIdentifier }

    var body: some View {
        HStack(spacing: 4) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
            windowCountBadge
        }
        .padding(.horizontal, tokens.spacing.edgePadding)
        .frame(width: width, height: tokens.panel.height - 8)
        .background(backgroundColor)
        .overlay(activeIndicator, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: tokens.taskButton.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture {
            // Primary click with no clear "the" window: raise the first one,
            // same as the ⌘⌥1…9 shortcut does for a group.
            if let first = windows.first {
                windowManager.raise(first)
            }
        }
        .help(appName)
        .onHover { hovering in
            windowManager.setGroupHovered(bundleIdentifier, hovering: hovering)
        }
        .contextMenu {
            Button(windowManager.isPinned(bundleIdentifier: bundleIdentifier) ? L("taskbar.unpin") : L("taskbar.pin")) {
                windowManager.togglePin(pid: windows.first?.pid ?? 0, bundleIdentifier: bundleIdentifier, displayName: appName)
            }
        }
        .taskReorderable(bundleIdentifier: realBundleIdentifier, windowManager: windowManager) {
            if let first = windows.first {
                windowManager.raise(first)
            }
        }
        .popover(isPresented: Binding(
            get: { windowManager.hoveredGroupID == bundleIdentifier },
            set: { if !$0 { windowManager.setGroupHovered(bundleIdentifier, hovering: false) } }
        ), arrowEdge: .top) {
            windowListPopover
        }
    }

    private var windowCountBadge: some View {
        Text("\(windows.count)")
            .font(.system(size: tokens.typography.fontSize - 2, weight: .semibold))
            .foregroundStyle(Color(hex: tokens.colors.textSecondary))
    }

    private var windowListPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(windows, id: \.id) { window in
                windowRow(window)
            }
        }
        .padding(6)
        .frame(minWidth: 220)
        .background(Color(hex: tokens.panel.backgroundColor))
        .onHover { hovering in
            windowManager.setGroupHovered(bundleIdentifier, hovering: hovering)
        }
    }

    private func windowRow(_ window: AppWindow) -> some View {
        HStack(spacing: 8) {
            Text(window.title)
                .font(.system(size: tokens.typography.fontSize))
                .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                .lineLimit(1)
                .opacity(window.isMinimized ? 0.6 : 1.0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    windowManager.activateOrMinimize(window)
                }

            Button {
                windowManager.toggleMinimize(window)
            } label: {
                Image(systemName: window.isMinimized ? "arrow.up.right.square" : "arrow.down.right.square")
            }
            .buttonStyle(.plain)
            .help(window.isMinimized ? L("window.restore") : L("window.minimize"))

            Button {
                windowManager.close(window)
            } label: {
                Image(systemName: "xmark.square")
            }
            .buttonStyle(.plain)
            .help(L("window.close"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(hex: tokens.colors.buttonBackgroundHover).opacity(0.001)) // keeps the whole row hit-testable
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contextMenu {
            Button(window.isMinimized ? L("window.restore") : L("window.minimize")) {
                windowManager.toggleMinimize(window)
            }
            Button(L("window.close")) {
                windowManager.close(window)
            }
        }
    }

    /// Same 0.3 Breeze `Metrics::Blend_Value` hover alpha used by
    /// `TaskButtonView` — see that file for the source reference.
    private var backgroundColor: Color {
        let accent = Color(hex: tokens.colors.accent)
        if isHovered { return accent.opacity(0.3) }
        if anyActive { return accent.opacity(0.15) }
        return .clear
    }

    @ViewBuilder
    private var activeIndicator: some View {
        if tokens.taskButton.indicatorStyle == "underline" && anyActive {
            Rectangle()
                .fill(Color(hex: tokens.colors.accent))
                .frame(height: 2)
        }
    }
}
