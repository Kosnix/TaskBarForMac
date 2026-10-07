import SwiftUI

/// The red Dock-style badge with an app's notification text ("3", "•", …)
/// pinned to its icon's top-trailing corner — the mirror of
/// `TaskWindowCountBadge` at the bottom, so both can show at once. Red, not
/// the theme's accent: that's what a notification badge means everywhere
/// else on macOS.
struct AppNotificationBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .frame(minWidth: 13, minHeight: 13)
            .background(Color(red: 0.93, green: 0.20, blue: 0.20), in: Capsule())
    }
}

extension View {
    @ViewBuilder
    func appNotificationBadge(_ label: String?) -> some View {
        if let label {
            overlay(alignment: .topTrailing) { AppNotificationBadge(label: label) }
        } else {
            self
        }
    }
}

/// Re-renders `content` twice a second with a flag that alternates while
/// `isActive` — fed to `.hoverLift` so an app asking for attention
/// zooms in and out like the Dock's bounce, reusing the hover animation.
struct AttentionPulse<Content: View>: View {
    let isActive: Bool
    @ViewBuilder let content: (Bool) -> Content

    private static var period: TimeInterval { 0.5 }

    var body: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: Self.period)) { context in
                content(Int(context.date.timeIntervalSinceReferenceDate / Self.period) % 2 == 0)
            }
        } else {
            content(false)
        }
    }
}

/// A thin progress bar along the bottom of an icon (a download, a file
/// copy), like Windows' taskbar progress — the theme's accent on a dark track.
struct AppProgressBar: View {
    let fraction: Double
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.45))
                Capsule().fill(accentColor).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 2)
        .padding(.bottom, 1)
    }
}

extension View {
    @ViewBuilder
    func appProgressBar(_ fraction: Double?, accentColor: Color) -> some View {
        if let fraction {
            overlay(alignment: .bottom) { AppProgressBar(fraction: fraction, accentColor: accentColor) }
        } else {
            self
        }
    }
}
