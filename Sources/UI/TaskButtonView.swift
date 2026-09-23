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
    private var iconSize: CGFloat { max(12, tokens.panel.height - 16) }

    var body: some View {
        HStack(spacing: 6) {
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
            if showLabel {
                Text(window.title)
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, tokens.spacing.edgePadding)
        .frame(width: width, height: tokens.panel.height - 8)
        .background(backgroundColor)
        .overlay(activeIndicator, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: tokens.taskButton.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .opacity(window.isMinimized ? 0.6 : 1.0)
        .onHover { isHovering in
            windowManager.hoveredWindowID = isHovering ? window.id : (windowManager.hoveredWindowID == window.id ? nil : windowManager.hoveredWindowID)
        }
        .contextMenu {
            Button(window.isMinimized ? L("window.restore") : L("window.minimize")) {
                windowManager.toggleMinimize(window)
            }
            Button(L("window.close")) {
                windowManager.close(window)
            }
            Divider()
            Button(windowManager.isPinned(bundleIdentifier: window.bundleIdentifier) ? L("taskbar.unpin") : L("taskbar.pin")) {
                windowManager.togglePin(pid: window.pid, bundleIdentifier: window.bundleIdentifier, displayName: window.appName)
            }
        }
        .help(showLabel ? "" : window.title)
        .taskReorderable(bundleIdentifier: window.bundleIdentifier, windowManager: windowManager) {
            windowManager.raise(window)
        }
    }

    private var isHovered: Bool { windowManager.hoveredWindowID == window.id }

    /// Breeze's kstyle hardcodes a flat 0.3 alpha for hover/highlight fills
    /// (`Metrics::Blend_Value` in breezemetrics.h, applied via
    /// `color.setAlphaF(Metrics::Blend_Value)` in breezestyle.cpp) — reused
    /// verbatim here instead of an eyeballed opacity.
    private static let breezeBlendValue: Double = 0.3

    private var backgroundColor: Color {
        let accent = Color(hex: tokens.colors.accent)
        if isHovered {
            return accent.opacity(Self.breezeBlendValue)
        }
        if !window.isMinimized {
            return accent.opacity(Self.breezeBlendValue / 2)
        }
        return .clear
    }

    @ViewBuilder
    private var activeIndicator: some View {
        if tokens.taskButton.indicatorStyle == "underline" && !window.isMinimized {
            Rectangle()
                .fill(Color(hex: tokens.colors.accent))
                .frame(height: 2)
        }
    }
}
