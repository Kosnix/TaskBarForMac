import AppKit
import SwiftUI

/// The taskbar panel's background, shared with the start menu popover so
/// both surfaces render identically — flat color, vibrancy blur, or (opt-in)
/// a "Liquid Glass"-style translucent look.
///
/// The Liquid Glass option originally wrapped the real system material,
/// `NSGlassEffectView` (macOS 26+). Two rounds of trying to fix it —
/// forcing `TaskbarPanel.isKeyWindow`, pinning its `NSAppearance` — didn't
/// stop it from washing out pale on focus loss, and it also plain refused
/// to show real transparency at all. That turned out to match a confirmed,
/// still-open Apple regression as of macOS 26.2: `NSGlassEffectView`
/// renders from a *cached* snapshot of what's behind the window that only
/// refreshes when the window itself moves — and doesn't refresh at all
/// when other content moves behind it — in exactly this panel's
/// configuration (borderless, transparent, `.canJoinAllSpaces`,
/// non-movable). Not something more tuning here can fix. `NSVisualEffectView`
/// with `.behindWindow` blending is the older, stable API, but it's the one
/// that actually delivers what was being asked for: real, live
/// see-through, an explicit "always render as active" switch that
/// genuinely works, and no caching bug — at the cost of not being the
/// literal newest system material.
struct PanelBackground: View {
    let tokens: ThemeTokens
    let liquidGlassEnabled: Bool
    /// 0 (as see-through as the material allows) to 1 (near-solid) — the
    /// slider next to the on/off toggle in the personalization menu.
    var liquidGlassIntensity: Double = 0.35
    /// The taskbar itself wants its hairline top border back (breeze/apple
    /// only — see `tokens.panel.borderWidth`); the start menu popover
    /// doesn't use this background for a border, so it passes `false`.
    var showTopBorder: Bool = true

    var body: some View {
        ZStack(alignment: .top) {
            if showTopBorder && tokens.panel.borderWidth > 0 {
                Color(hex: tokens.panel.borderColor)
            }
            content
                .padding(.top, showTopBorder ? tokens.panel.borderWidth : 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if liquidGlassEnabled {
            // `.behindWindow` genuinely samples the desktop at the
            // compositor level — real transparency, not a simulated one —
            // now safe to lean on fully since the real Dock goes back to
            // being `autohide`d (off-screen), so there's nothing behind
            // this panel that shouldn't be seen. A light theme-colored
            // tint on top keeps it reading as "this theme's glass", not
            // just a generic blur.
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color(hex: tokens.panel.backgroundColor).opacity(liquidGlassIntensity)
            }
            .opacity(tokens.panel.backgroundOpacity)
        } else if tokens.panel.blurEnabled {
            // `.behindWindow` blur would sample whatever is actually behind
            // our window at the compositor level — the real Dock (before
            // it's auto-hidden) or the desktop — and show it through,
            // blurred. Layering `.withinWindow` vibrancy over an opaque
            // color underneath gives a frosted look while staying fully
            // opaque.
            ZStack {
                Color(hex: tokens.panel.backgroundColor)
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    .opacity(0.6)
            }
            .opacity(tokens.panel.backgroundOpacity)
        } else {
            Color(hex: tokens.panel.backgroundColor).opacity(tokens.panel.backgroundOpacity)
        }
    }
}

/// Same idea as `PanelBackground` but sized for a single button (minimize-
/// all, trash) rather than the whole bar — flat color normally, or the
/// Liquid Glass look when that's enabled, so the right-side buttons pick
/// up the same opt-in look as the bar itself.
struct GlassButtonBackground: View {
    let tokens: ThemeTokens
    let liquidGlassEnabled: Bool
    var liquidGlassIntensity: Double = 0.35
    var cornerRadius: CGFloat = 0

    var body: some View {
        if liquidGlassEnabled {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color(hex: tokens.colors.buttonBackground).opacity(liquidGlassIntensity)
            }
        } else {
            Color(hex: tokens.colors.buttonBackground)
        }
    }
}
