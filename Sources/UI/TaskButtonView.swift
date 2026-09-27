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
        // Positioned by hand (not a plain `.overlay` on the icon) — the
        // icon sits inside an `HStack` whose default cross-axis alignment
        // is `.center`, so when the button is taller than the icon (icon
        // shrunk by the fixed 16pt inset, button only by 8pt) the icon
        // itself floats vertically centered within that extra height —
        // and a dot attached to the icon would float right along with it,
        // away from the button's true bottom edge. Horizontal position
        // still tracks the icon (its known offset from the leading edge:
        // the button's own edge padding, then half the icon's width);
        // vertical position is pinned to the button's bottom edge only.
        .overlay(alignment: .bottomLeading) {
            minimizedDot
                .offset(x: tokens.effectiveTaskbarEdgePadding + iconSize / 2 - Self.minimizedDotSize / 2, y: -Self.minimizedDotBottomInset)
        }
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
            // Unpinning specifically is edit-mode-only (detaching an icon
            // is an edit, same as reordering/re-skinning one) — pinning a
            // not-yet-pinned one isn't, since that's not removing anything
            // from the bar.
            if windowManager.isPinned(bundleIdentifier: window.bundleIdentifier) {
                if windowManager.isEditingIcons {
                    Button(L("taskbar.unpin")) {
                        windowManager.togglePin(pid: window.pid, bundleIdentifier: window.bundleIdentifier, displayName: window.appName)
                    }
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

    private static let minimizedDotSize: CGFloat = 4
    private static let minimizedDotBottomInset: CGFloat = 2

    // A minimized window used to just dim its whole button (opacity 0.6) —
    // replaced with a small dot underneath, matching the real Dock's own
    // "open app" indicator convention, so a minimized window still reads
    // clearly (icon, label) and only the dot communicates its state.
    @ViewBuilder
    private var minimizedDot: some View {
        if window.isMinimized {
            Circle()
                .fill(Color(hex: tokens.colors.textSecondary))
                .frame(width: Self.minimizedDotSize, height: Self.minimizedDotSize)
        }
    }

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
