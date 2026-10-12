import AppKit
import SwiftUI

/// The taskbar panel's background, shared with the start menu popover so
/// both surfaces render identically — flat color, vibrancy blur, or (opt-in)
/// a "Liquid Glass"-style translucent look.
///
/// The Liquid Glass option originally wrapped the real system material,
/// `NSGlassEffectView` (macOS 26+). Three rounds of trying to fix it —
/// forcing `TaskbarPanel`/`StartMenuPanel.isKeyWindow`, pinning
/// `NSAppearance`, retrying on macOS 27 — didn't stop it from washing out
/// pale/blank on focus loss, confirmed again once the start menu (a much
/// bigger surface than the thin taskbar, where it was probably happening
/// unnoticed) rendered solid white instead of translucent. Research into
/// public reports confirms this isn't something more client-side tuning can
/// fix: Apple's own developer forums have multiple *unresolved* threads
/// describing the exact same window shape as this app's (borderless,
/// non-activating, `.canJoinAllSpaces`, moved only programmatically) —
/// `NSGlassEffectView` renders from a snapshot that's only invalidated when
/// the window itself moves (not when whatever's behind it changes), and
/// separately, a non-key panel is stuck showing the material's "inactive"
/// look with no documented workaround. A second real shipping app hit the
/// identical wall and disabled `NSGlassEffectView` for SwiftUI content on
/// macOS 26+ entirely, and had to special-case macOS 27 again after a tint
/// compositing change made a themed tint render fully opaque instead of
/// translucent there. So this stays on the `NSVisualEffectView`-based
/// simulation for good — the effort instead goes into making *that* read
/// as close to the real material as possible (see `content` below).
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
        // A gradient bar (Windows XP) is its own opaque look: no glass, no
        // border — only on the taskbar itself, never behind a menu, where a
        // bar-height ramp stretched over a tall panel would just look wrong.
        if showTopBorder, let gradient = tokens.panel.gradient {
            ZStack(alignment: .top) {
                if tokens.panel.blurEnabled {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, appearance: tokens.materialAppearance)
                }
                gradient.linear
                VStack(spacing: 0) {
                    if let dark = tokens.panel.edgeDark {
                        Rectangle().fill(Color(hex: dark)).frame(height: 1)
                    }
                    if let edge = tokens.panel.edgeHighlight {
                        Rectangle().fill(Color(hex: edge)).frame(height: 1)
                    }
                }
            }
        } else {
            flatOrGlass
        }
    }

    private var flatOrGlass: some View {
        ZStack(alignment: .top) {
            if showTopBorder && tokens.panel.borderWidth > 0 {
                Color(hex: tokens.panel.borderColor)
            }
            content
                .padding(.top, showTopBorder ? tokens.panel.borderWidth : 0)
        }
    }

    /// The theme color, tinted to `liquidGlassIntensity`'s own alpha — a
    /// clear tint reads as pure, untinted glass; a heavily tinted one reads
    /// as a strongly-colored glass. Capped at 0.85 (not 1) so the blur
    /// layered underneath is never fully hidden — even at the slider's
    /// maximum, this should still read as tinted *glass*, not a flat,
    /// solid-color panel.
    private var glassTintColor: Color {
        Color(hex: tokens.panel.backgroundColor).opacity(liquidGlassIntensity * 0.85)
    }

    @ViewBuilder
    private var content: some View {
        if liquidGlassEnabled {
            // `.behindWindow` genuinely samples the desktop at the
            // compositor level — real transparency, not a simulated one. A
            // light theme-colored tint on top keeps it reading as "this
            // theme's glass", not just a generic blur.
            //
            // The blur used to fade out as the tint rose (opacity
            // `1 - intensity * 0.85`), so the low end of the slider read as
            // pure blur with barely any tint, and the high end read as a
            // flat opaque color with the blur almost gone — blur and
            // transparency were never really visible *together*. The blur
            // now stays at full strength across the whole range; only the
            // tint's own opacity tracks the slider, and even at its most
            // intense it's capped short of fully opaque, so the blur is
            // always still showing through underneath.
            ZStack {
                // `.popover` turned out to be the wrong pick: on macOS 27,
                // Apple quietly rebuilt several materials (confirmed for
                // `.selection`, and `.popover` was never confirmed to have
                // survived either) to drop their `CABackdropLayer` — the
                // actual live-blur layer — entirely, so there was nothing
                // left to blend regardless of blending mode. `.sidebar`
                // (like `.underWindowBackground`/`.hudWindow`) is confirmed
                // to still carry that layer on macOS 27 and to honor the
                // system's own Liquid Glass transparency slider, while
                // reading much lighter than `.hudWindow`'s deliberately
                // dark HUD tone.
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow, appearance: tokens.materialAppearance)
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
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, appearance: tokens.materialAppearance)
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
    /// Whether a glass bar (Aero) shows this as a pane of glass — the
    /// show-desktop strip — rather than leaving it to the bar itself.
    var isPane = false

    var body: some View {
        if tokens.panel.gradient != nil && !isPane {
            Color.clear
        } else if tokens.panel.gradient != nil && tokens.tray != nil {
            // On an opaque gradient bar (Windows XP) a button is just its
            // icon — the bar itself is the surface.
            Color.clear
        } else if tokens.panel.gradient != nil {
            // On an Aero glass bar, a button is a lighter pane of glass.
            LinearGradient(
                stops: [.init(color: .white.opacity(0.28), location: 0), .init(color: .white.opacity(0.1), location: 0.5), .init(color: .white.opacity(0.03), location: 0.5), .init(color: .white.opacity(0.16), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        } else if liquidGlassEnabled {
            // Same reasoning as `PanelBackground.glassTintColor` — blur
            // stays constant, only the tint's opacity (capped short of
            // fully opaque) tracks the slider.
            let tint = Color(hex: tokens.colors.buttonBackground).opacity(liquidGlassIntensity * 0.85)
            ZStack {
                // Same material as `PanelBackground` — see its doc comment.
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow, appearance: tokens.materialAppearance)
                tint
            }
        } else {
            Color(hex: tokens.colors.buttonBackground)
        }
    }
}
