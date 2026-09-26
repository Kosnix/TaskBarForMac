import AppKit
import SwiftUI

/// The taskbar panel's background, shared with the start menu popover so
/// both surfaces render identically — flat color, vibrancy blur, or (opt-in)
/// a "Liquid Glass"-style translucent look.
///
/// The Liquid Glass option originally wrapped the real system material,
/// `NSGlassEffectView` (macOS 26+). Three rounds of trying to fix it now —
/// forcing `TaskbarPanel`/`StartMenuPanel.isKeyWindow`, pinning
/// `NSAppearance`, retrying on macOS 27 — didn't stop it from washing out
/// pale/blank on focus loss, confirmed again once the start menu (a much
/// bigger surface than the thin taskbar, where it was probably happening
/// unnoticed) rendered solid white instead of translucent. This matches
/// the same still-open Apple regression already documented before: it
/// renders from a *cached* snapshot of what's behind the window that only
/// refreshes when the window itself moves — exactly the situation for a
/// borderless, non-activating, `.canJoinAllSpaces` panel like this app's.
/// Not something more tuning here can fix — back to the
/// `NSVisualEffectView`-based simulation for good.
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

    /// The theme color, tinted to `liquidGlassIntensity`'s own alpha — a
    /// clear tint reads as pure, untinted glass; a fully opaque one reads
    /// as a near-solid, theme-colored panel. Shared by both the real
    /// `NSGlassEffectView` (whose own `tintColor` takes this directly) and
    /// the simulated fallback (layered as a plain SwiftUI `Color` on top).
    private var glassTintColor: Color {
        Color(hex: tokens.panel.backgroundColor).opacity(liquidGlassIntensity)
    }

    @ViewBuilder
    private var content: some View {
        if liquidGlassEnabled {
            // `.behindWindow` genuinely samples the desktop at the
            // compositor level — real transparency, not a simulated one. A
            // light theme-colored tint on top keeps it reading as "this
            // theme's glass", not just a generic blur.
            //
            // The tint's own opacity was the only thing the slider moved —
            // since a fully-opaque tint already hides the blur underneath
            // regardless, the two ends of the range looked right, but
            // everything *between* them barely felt different. Fading the
            // blur's own opacity down as the tint rises makes the whole
            // slider track produce a visibly different look end to end,
            // not just at its extremes.
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(1 - liquidGlassIntensity * 0.85)
                glassTintColor
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
            let tint = Color(hex: tokens.colors.buttonBackground).opacity(liquidGlassIntensity)
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(1 - liquidGlassIntensity * 0.85)
                tint
            }
        } else {
            Color(hex: tokens.colors.buttonBackground)
        }
    }
}
