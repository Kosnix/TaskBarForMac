import SwiftUI

// Windows XP ("Luna") pieces that a theme switches on through its tokens
// rather than through code of its own: the raised task buttons, the green
// start tab and the notification area's tinted block. Any theme can use
// them by declaring `taskButton.raised`, `startButton.tab` and `tray`.

/// A task button's bevelled body: raised and blue while the window is open,
/// lighter under the pointer, pressed in (darker, shadowed at the top and
/// left) while it's the active window.
struct RaisedTaskButtonBackground: View {
    let raised: RaisedButtonTokens
    let isActive: Bool
    let isHovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: raised.cornerRadius)
        let fill = isActive ? raised.activeFill : (isHovered ? raised.hoverFill : raised.fill)
        ZStack {
            shape.fill(fill.linear)
            if isActive {
                shape.inset(by: 1)
                    .strokeBorder(
                        LinearGradient(colors: [Color.black.opacity(0.38), Color.black.opacity(0)], startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.7)),
                        lineWidth: 1.5
                    )
            } else {
                shape.inset(by: 1)
                    .strokeBorder(
                        LinearGradient(colors: [Color(hex: raised.highlight).opacity(0.85), Color(hex: raised.highlight).opacity(0)], startPoint: .topLeading, endPoint: UnitPoint(x: 0.7, y: 0.8)),
                        lineWidth: 1
                    )
            }
            shape.strokeBorder(Color(hex: isActive ? raised.activeBorder : raised.border), lineWidth: 1)
        }
    }
}

/// The green "start" tab: flush with the bar's left edge, rounded on the
/// right, with the flag and an italic bold "start".
struct LunaStartButtonLabel: View {
    let tab: StartTabTokens
    let tokens: ThemeTokens
    /// The theme's own flag picture (`icons/start-flag.png`); the drawn
    /// `LunaFlag` stands in when a theme doesn't ship one.
    var flagURL: URL?
    let isHovered: Bool
    @Environment(\.isButtonPressed) private var isPressed

    var body: some View {
        let height = tokens.panel.height
        let radius = min(CGFloat(tab.cornerRadius), height * 0.5)
        let fill = isPressed ? tab.pressedFill : (isHovered ? tab.hoverFill : tab.fill)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius)
        HStack(spacing: height * 0.12) {
            Group {
                if let flagURL, let flag = ThemeIconLoader.image(at: flagURL, tinted: "#FFFFFF") {
                    Image(nsImage: flag).resizable().aspectRatio(contentMode: .fit)
                } else {
                    LunaFlag()
                }
            }
            .frame(width: height * 0.62, height: height * 0.62)
            .shadow(color: .black.opacity(0.35), radius: 0.8, x: 0.5, y: 1)
            // The word is the language's own ("start", "démarrer",
            // "Inicio", "Пуск").
            Text(L("xp.start"))
                .font(.custom("Trebuchet MS", size: height * 0.5).weight(.bold).italic())
                .foregroundStyle(Color(hex: tab.textColor))
                .shadow(color: Color(hex: tab.textShadow), radius: 0, x: 1, y: 1.2)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, height * 0.24)
        .padding(.trailing, height * 0.42)
        .frame(height: height)
        .background(
            ZStack {
                shape.fill(fill.linear)
                // The glossy top edge.
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.38), Color.white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
                    .padding(.top, 1)
                shape.strokeBorder(Color(hex: tab.border), lineWidth: 1)
            }
        )
        .offset(y: isPressed ? 0.5 : 0)
    }
}

/// The four-pane waving Windows flag.
struct LunaFlag: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            // Each pane: a quad with slightly bowed top and bottom edges,
            // the right-hand ones sitting a little higher (the wave).
            func pane(_ x: CGFloat, _ y: CGFloat, _ color: Color, rise: CGFloat) {
                var path = Path()
                let pw = w * 0.45, ph = h * 0.42
                path.move(to: CGPoint(x: x, y: y + rise + ph * 0.06))
                path.addQuadCurve(to: CGPoint(x: x + pw, y: y - rise * 0.2), control: CGPoint(x: x + pw * 0.5, y: y + rise - ph * 0.08))
                path.addLine(to: CGPoint(x: x + pw, y: y - rise * 0.2 + ph))
                path.addQuadCurve(to: CGPoint(x: x, y: y + rise + ph * 0.06 + ph), control: CGPoint(x: x + pw * 0.5, y: y + rise + ph * 0.92))
                path.closeSubpath()
                context.fill(path, with: .color(color))
                context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.4)
            }
            pane(w * 0.04, h * 0.08, Color(red: 0.95, green: 0.31, blue: 0.11), rise: h * 0.03)
            pane(w * 0.53, h * 0.04, Color(red: 0.49, green: 0.74, blue: 0.18), rise: h * 0.01)
            pane(w * 0.04, h * 0.52, Color(red: 0.0, green: 0.60, blue: 0.90), rise: h * 0.03)
            pane(w * 0.53, h * 0.48, Color(red: 1.0, green: 0.72, blue: 0.0), rise: h * 0.01)
        }
    }
}

/// The notification area's tinted block with its bevelled left edge.
struct TrayBackground: View {
    let tray: TrayTokens

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(tray.fill.linear)
            Rectangle().fill(Color(hex: tray.border)).frame(width: 1)
            Rectangle().fill(Color(hex: tray.highlight)).frame(width: 1).offset(x: 1)
        }
    }
}

/// Windows 7's Start orb: the theme's three pictures of it (`start-button`,
/// `start-button-hover`, `start-button-pressed`), swapped for the pointer's
/// state with a short cross-fade. The pictures carry transparent margins and
/// the hover glow, so they're drawn larger than the bar is tall
/// (`startButton.fillScale`) — the orb itself ends up a little smaller than
/// the bar, with the glow free to spill into the margin.
struct OrbStartButtonLabel: View {
    let theme: Theme
    let tokens: ThemeTokens
    let isHovered: Bool
    @Environment(\.isButtonPressed) private var isPressed

    private func picture(_ name: String, visible: Bool, size: CGFloat) -> some View {
        Group {
            if let url = theme.iconURL(name), let image = ThemeIconLoader.image(at: url, tinted: "#FFFFFF") {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .opacity(visible ? 1 : 0)
    }

    var body: some View {
        let size = tokens.panel.height * (tokens.startButton.fillScale ?? 1)
        let state = isPressed ? 2 : (isHovered ? 1 : 0)
        ZStack {
            picture("start-button", visible: state == 0, size: size)
            picture("start-button-hover", visible: state == 1, size: size)
            picture("start-button-pressed", visible: state == 2, size: size)
        }
        .animation(.easeOut(duration: 0.12), value: state)
        // The layout width stops at the orb's right edge (about 80% of the
        // picture), so the next icon sits right after it instead of after
        // the picture's transparent margin; the picture itself overflows.
        .frame(width: size * 0.8, height: tokens.panel.height, alignment: .leading)
        // The picture's own transparent margin sits left of the orb; pull it
        // back so the orb ends up a few points in from the screen edge.
        .padding(.leading, -9)
    }
}
