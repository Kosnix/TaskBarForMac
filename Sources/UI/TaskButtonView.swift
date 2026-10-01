import SwiftUI

/// A single running-window button in the task list, styled entirely from the
/// active theme's tokens (no hardcoded Plasma/GNOME/Windows-specific styling
/// here — that's what makes the taskbar itself theme-agnostic).
///
/// The hover/active fill uses a translucent accent tint rather than a flat
/// button color, matching how Breeze's own widget style highlights task
/// buttons. Width and whether the title is shown are decided by the caller
/// (see `TaskbarView`'s adaptive task list), so buttons shrink to fit
/// instead of overflowing the panel when many windows are open.
///
/// Deliberately not a `Button`: a `Button`'s own click recognizer competes
/// with `.draggable`'s drag recognizer for the initial mouse-down, which is
/// why drag-to-reorder didn't work — a plain tappable view doesn't have
/// that conflict.
struct TaskButtonView: View {
    let window: AppWindow
    let tokens: ThemeTokens
    let windowManager: WindowManager
    let width: CGFloat
    let showLabel: Bool
    let onTap: () -> Void

    /// Icon fills most of the button's height, which itself tracks the
    /// panel height — so icons scale up automatically when the panel is
    /// resized instead of staying a fixed, disproportionately small size.
    private var iconSize: CGFloat { tokens.taskbarIconSize }

    var body: some View {
        HStack(spacing: 6) {
            if let icon = windowManager.resolvedIcon(bundleIdentifier: window.bundleIdentifier, fallback: window.appIcon) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .wiggle(isActive: windowManager.isEditingIcons, seed: window.id.hashValue)
                    .hoverLift(isHovered: isHovered, zoomRatio: tokens.effectiveTaskbarIconHoverZoom)
                    // A single open window needs no indicator at all — only
                    // once it's minimized is there anything worth flagging,
                    // shown as "1" in the same badge style
                    // `GroupedTaskButtonView` uses for its own window count.
                    .taskWindowCountBadge(window.isMinimized ? .empty : nil, accentColor: Color(hex: tokens.colors.accent))
            }
            if showLabel {
                Text(window.title)
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, tokens.effectiveTaskbarEdgePadding)
        // Left-aligned, not the default center — see `GroupedTaskButtonView`
        // for why this specific change matters (a wide allocated `width`
        // with modest content otherwise leaves empty space before the icon
        // too, not just after it).
        .frame(width: width, height: tokens.panel.height - 8, alignment: .leading)
        .overlay(activeUnderline, alignment: .bottom)
        // No more `.clipShape` here — there's no background fill left to
        // round the corners of (see `backgroundColor`'s removal above),
        // and clipping to the button's own bounds was cutting off
        // `.hoverLift`'s shadow, which needs to spill past the icon.
        .contentShape(Rectangle())
        .contextMenu {
            // Not while editing icons — the same reason a left-click stops
            // minimizing/raising in this mode: jiggling is for
            // rearranging/re-skinning icons, not controlling windows.
            if !windowManager.isEditingIcons {
                Button(window.isMinimized ? L("window.restore") : L("window.minimize")) {
                    windowManager.toggleMinimize(window)
                }
                Button(L("window.close")) {
                    windowManager.close(window)
                }
                Divider()
            }
            // Unpinning works outside edit mode too now.
            if windowManager.isPinned(bundleIdentifier: window.bundleIdentifier) {
                Button(L("taskbar.unpin")) {
                    windowManager.togglePin(pid: window.pid, bundleIdentifier: window.bundleIdentifier, displayName: window.appName)
                }
            } else {
                Button(L("taskbar.pin")) {
                    windowManager.togglePin(pid: window.pid, bundleIdentifier: window.bundleIdentifier, displayName: window.appName)
                }
            }
            if windowManager.isEditingIcons {
                Button(L("icon_edit.change")) {
                    windowManager.presentIconPicker(for: window.bundleIdentifier)
                }
                if windowManager.hasCustomIcon(bundleIdentifier: window.bundleIdentifier) {
                    Button(L("icon_edit.restore_original")) {
                        windowManager.restoreOriginalIcon(for: window.bundleIdentifier)
                    }
                }
            }
        }
        .help(showLabel ? "" : window.title)
        .taskReorderable(bundleIdentifier: window.bundleIdentifier, windowManager: windowManager) {
            windowManager.raise(window)
        }
        // Last: this app's own raw-AppKit tap/long-press/drag overlay needs
        // to sit on top of everything else here (`.taskReorderable`'s own
        // `.onDrop` target especially) to actually receive left-clicks —
        // see `IconPressGesture.swift`'s doc comment for why an earlier
        // ordering silently ate every click before it ever reached this.
        .iconPressAndHold(windowManager: windowManager, bundleIdentifier: window.bundleIdentifier, onTap: onTap) { isHovering in
            windowManager.hoveredWindowID = isHovering ? window.id : (windowManager.hoveredWindowID == window.id ? nil : windowManager.hoveredWindowID)
        }
    }

    private var isHovered: Bool { windowManager.hoveredWindowID == window.id }

    // Neither a running window nor hover get a flat background tint any
    // more — an open app reads from `activeUnderline` alone, and hover
    // reads from `.hoverLift`'s scale/shadow instead of a filled block.

    /// The theme's "active tab" underline (a different indicator style from
    /// the minimized dot) genuinely spans the whole button, not just the
    /// icon, so it stays on the outer frame.
    @ViewBuilder
    private var activeUnderline: some View {
        if !window.isMinimized && tokens.taskButton.indicatorStyle == "underline" {
            Rectangle()
                .fill(Color(hex: tokens.colors.accent))
                .frame(height: 2)
        }
    }
}
