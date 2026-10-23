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

    var body: some View {
        let accent = Color(hex: tokens.taskButton.indicatorColor ?? tokens.colors.accent)
        let idle = Color(hex: tokens.colors.textSecondary)
        switch tokens.taskButton.indicatorStyle {
        case "bar":
            let segments = min(max(windowCount, 1), 3)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { _ in
                    Rectangle().fill(isActive ? accent : idle).frame(maxWidth: isActive ? .infinity : 10)
                }
            }
            .frame(width: isActive ? nil : (CGFloat(segments) * 10 + CGFloat(segments - 1) * 2), height: 2)
            .padding(.horizontal, isActive ? 4 : 0)
            .padding(.bottom, 1)
        case "pill":
            Capsule()
                .fill(isActive ? accent : idle)
                .frame(width: isActive ? 16 : 6, height: 3)
                .padding(.bottom, 2)
        case "underline":
            if !isMinimized {
                Rectangle().fill(Color(hex: tokens.colors.accent)).frame(height: 2)
            }
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
