import SwiftUI

/// The hover popup with a thumbnail card per window (see `GroupHoverPanel`):
/// the window's picture, its title and a close button on hover. A window
/// with no picture to show (minimized, or Screen Recording not granted)
/// gets its app icon on the card instead.
struct WindowPreviewStrip: View {
    let windows: [AppWindow]
    let tokens: ThemeTokens
    let windowManager: WindowManager
    let bundleIdentifier: String
    let thumbnails: WindowThumbnailStore

    static let cardWidth: CGFloat = 190
    static let cardImageHeight: CGFloat = 118

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(windows, id: \.id) { window in
                WindowPreviewCard(window: window, tokens: tokens, windowManager: windowManager, image: window.cgWindowID.flatMap { thumbnails.images[$0] })
            }
        }
        .padding(8)
        .background(Color(hex: tokens.panel.backgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: max(6, tokens.taskButton.cornerRadius)))
        .overlay(
            RoundedRectangle(cornerRadius: max(6, tokens.taskButton.cornerRadius))
                .strokeBorder(Color(hex: tokens.colors.textSecondary).opacity(0.25), lineWidth: 1)
        )
        .shadow(radius: 8)
        .onHover { hovering in
            windowManager.setGroupHovered(bundleIdentifier, hovering: hovering)
        }
    }
}

private struct WindowPreviewCard: View {
    let window: AppWindow
    let tokens: ThemeTokens
    let windowManager: WindowManager
    let image: NSImage?

    var body: some View {
        let isHovered = windowManager.hoveredPreviewWindowID == window.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon = window.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(window.title.isEmpty ? window.appName : window.title)
                    .font(.system(size: tokens.typography.fontSize))
                    .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    windowManager.close(window)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(hex: tokens.colors.textSecondary).opacity(0.25)))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.25))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(window.isMinimized ? 0.55 : 1)
                } else if let icon = window.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48).opacity(0.8)
                }
            }
            .frame(width: WindowPreviewStrip.cardWidth, height: WindowPreviewStrip.cardImageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(6)
        .frame(width: WindowPreviewStrip.cardWidth + 12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: tokens.colors.accent).opacity(isHovered ? 0.28 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                windowManager.hoveredPreviewWindowID = window.id
            } else if windowManager.hoveredPreviewWindowID == window.id {
                windowManager.hoveredPreviewWindowID = nil
            }
        }
        .onTapGesture { windowManager.activateOrMinimize(window) }
        .contextMenu {
            Button(window.isMinimized ? L("window.restore") : L("window.minimize")) {
                windowManager.toggleMinimize(window)
            }
            Button(L("window.close")) { windowManager.close(window) }
        }
    }
}
