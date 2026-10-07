import SwiftUI

private struct IsButtonPressedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var isButtonPressed: Bool {
        get { self[IsButtonPressedKey.self] }
        set { self[IsButtonPressedKey.self] = newValue }
    }
}

/// Plain look, but tells its label whether the button is held down — a
/// SwiftUI `Button` only exposes that to a `ButtonStyle`.
struct PressReportingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.isButtonPressed, configuration.isPressed)
    }
}

/// `.hoverLift` for the start button: same lift on hover, same shrink while
/// held down as the taskbar icons (which get theirs from `PressAndHoldView`).
struct StartButtonLift<Content: View>: View {
    @Environment(\.isButtonPressed) private var isPressed
    let isHovered: Bool
    let zoomRatio: Double
    @ViewBuilder let content: Content

    var body: some View {
        content.hoverLift(isHovered: isHovered, zoomRatio: zoomRatio, isPressed: isPressed, disablesHitTesting: false)
    }
}

/// A subtle "lifting off the screen" hover effect for a taskbar icon: a
/// small scale-up plus a soft shadow underneath, as if the icon had popped
/// up above the bar's surface — instead of (or alongside) a flat
/// background tint. `zoomRatio` is `ThemeTokens.taskbarIconHoverZoomRatio`
/// (a plain fraction, e.g. 0.12 for +12%) — adjustable in Settings, same as
/// the icon's own size/spacing ratios.
extension View {
    func hoverLift(isHovered: Bool, zoomRatio: Double, isPressed: Bool = false, disablesHitTesting: Bool = true) -> some View {
        self
            // Shadow applied *before* the scale, not after: the icon and
            // its shadow become one fixed unit that grows together, rather
            // than a shadow being recomputed each frame against content
            // that's mid-scale — which both flickered on some icons and,
            // worse, could visibly render the shadow layer ahead of/on top
            // of the icon for a frame during the transition.
            .shadow(color: .black.opacity(isHovered && !isPressed ? 0.35 : 0), radius: isHovered && !isPressed ? 6 : 0, x: 0, y: isHovered && !isPressed ? 4 : 0)
            // Held down, the icon shrinks below its resting size (the
            // Windows "pressed" look) instead of staying lifted.
            .scaleEffect(isPressed ? 0.88 : (isHovered ? 1 + zoomRatio : 1))
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            // The enlarged, shadowed render must stay purely visual for a
            // taskbar icon — without this, its bigger on-screen bounds can
            // overlap a tightly-spaced neighbor and steal *its* hover,
            // which un-grows this one, which gives hover back, and so on: a
            // genuine flicker loop between adjacent icons. Only the
            // button's own unscaled frame (its `.onHover`/`.contentShape`)
            // should ever decide who's hovered. The start button is the one
            // exception (`disablesHitTesting: false`): it's a native
            // SwiftUI `Button`, which needs its own label to stay
            // hit-testable to actually be clickable at all — unlike the
            // taskbar icons, which are clicked via this app's own separate
            // AppKit overlay (`PressAndHoldView`), not the icon itself.
            .allowsHitTesting(!disablesHitTesting)
    }
}
