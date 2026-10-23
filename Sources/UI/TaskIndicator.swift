import SwiftUI

/// What a task button shows for "this app is running": Windows 10's bar
/// (short and grey when the app is open, long and accent-coloured when it's
/// the active one, split in segments for several windows) and Windows 11's
/// pill (a dot, stretching into a pill when active). Other themes keep the
/// plain accent underline under every non-minimized window.
struct TaskIndicator: View {
    let tokens: ThemeTokens
    let isActive: Bool
    let isMinimized: Bool
    let windowCount: Int
    var showLabel = false

    /// Vertical offset that centres a line of `height` in the gap between the
    /// icon's artwork (macOS icons keep ~10% transparent margin) and the bar's
    /// bottom edge. The button floats 4pt above that edge and the line starts
    /// flush with the button's bottom.
    private func lift(_ height: CGFloat) -> CGFloat {
        let size = tokens.taskbarIconSize
        let room = (tokens.panel.height - size) / 2 + size * 0.1
        return room / 2 - 4 - height / 2
    }

    /// Icon-only buttons overlap or touch their neighbours, so the line is kept
    /// shorter than the icon to leave a break between two running apps.
    private var lineWidth: CGFloat? { showLabel ? nil : tokens.taskbarIconSize * 0.7 }

    /// Where the "minimized" dot sits (the icon's bottom-trailing corner),
    /// relative to the line's resting spot: the one shape the line turns into
    /// (and back from) when its window is minimized. Only the themes with that
    /// dot (no raised button, no indicator bar) — `TaskButtonView` draws this
    /// indicator in front of the icon for them, as the dot has no separate badge.
    static func morphsToDot(_ tokens: ThemeTokens, windowCount: Int) -> Bool {
        tokens.taskButton.raised == nil && !tokens.usesIndicatorBar && windowCount == 1
    }

    private var dotTarget: CGSize? {
        guard Self.morphsToDot(tokens, windowCount: windowCount) else { return nil }
        let size = tokens.taskbarIconSize
        let iconBottom = (tokens.panel.height - 8 - size) / 2
        let dotCentreY = iconBottom + 2.5
        return CGSize(width: tokens.effectiveTaskbarEdgePadding + size - 0.5, height: TaskWindowCountBadge.emptyDiameter / 2 - dotCentreY)
    }

    var body: some View {
        GeometryReader { geo in
            let full = lineWidth ?? max(0, geo.size.width - 8)
            ZStack(alignment: .bottom) {
                indicator(full: full, buttonWidth: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isMinimized)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: windowCount)
    }

    @ViewBuilder
    private func indicator(full: CGFloat, buttonWidth: CGFloat) -> some View {
        let accent = Color(hex: tokens.taskButton.indicatorColor ?? tokens.colors.accent)
        let idle = Color(hex: tokens.colors.textSecondary)
        switch tokens.taskButton.indicatorStyle {
        case "bar":
            let segments = CGFloat(min(max(windowCount, 1), 3))
            HStack(spacing: 2) {
                ForEach(0..<Int(segments), id: \.self) { _ in
                    Capsule().fill(isActive ? accent : idle)
                        .frame(width: isActive ? (full - 2 * (segments - 1)) / segments : 10, height: 2)
                }
            }
            .offset(y: -lift(2))
        case "pill":
            Capsule().fill(isActive ? accent : idle)
                .frame(width: isActive ? 16 : 6, height: 3)
                .offset(y: -lift(3))
        case "underline":
            // Minimized: shrinks into the badge dot (which grows in front of
            // the icon at the same moment) or, without one, just fades.
            let target = isMinimized ? dotTarget : nil
            let side = TaskWindowCountBadge.emptyDiameter
            Capsule().fill(Color(hex: tokens.colors.accent))
                .frame(width: target == nil ? full : side, height: target == nil ? 2 : side)
                // The badge dot's white ring, fading in as the line becomes it
                // (before `.offset`, which moves the drawing but not the layout
                // frame an overlay attaches to).
                .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1).opacity(target == nil ? 0 : 1))
                .offset(x: target.map { $0.width - buttonWidth / 2 } ?? 0, y: target?.height ?? -lift(2))
                .opacity(isMinimized && dotTarget == nil ? 0 : 1)
        default:
            EmptyView()
        }
    }
}

/// The rounded plate Windows 10/11 draw behind a hovered (or active) task button.
struct TaskHoverPlate: View {
    let tokens: ThemeTokens
    let isHovered: Bool
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: tokens.taskButton.cornerRadius)
            .fill(Color(hex: tokens.colors.textPrimary).opacity(isHovered ? 0.12 : (isActive ? 0.07 : 0)))
    }
}
