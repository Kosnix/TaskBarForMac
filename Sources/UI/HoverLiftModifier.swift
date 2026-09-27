import SwiftUI

/// A subtle "lifting off the screen" hover effect for a taskbar icon: a
/// small scale-up plus a soft shadow underneath, as if the icon had popped
/// up above the bar's surface — instead of (or alongside) a flat
/// background tint. `zoomRatio` is `ThemeTokens.taskbarIconHoverZoomRatio`
/// (a plain fraction, e.g. 0.12 for +12%) — adjustable in Settings, same as
/// the icon's own size/spacing ratios.
extension View {
    func hoverLift(isHovered: Bool, zoomRatio: Double, disablesHitTesting: Bool = true) -> some View {
        self
            // Shadow applied *before* the scale, not after: the icon and
            // its shadow become one fixed unit that grows together, rather
            // than a shadow being recomputed each frame against content
            // that's mid-scale — which both flickered on some icons and,
            // worse, could visibly render the shadow layer ahead of/on top
            // of the icon for a frame during the transition.
            .shadow(color: .black.opacity(isHovered ? 0.35 : 0), radius: isHovered ? 6 : 0, x: 0, y: isHovered ? 4 : 0)
            .scaleEffect(isHovered ? 1 + zoomRatio : 1)
            .animation(.easeOut(duration: 0.15), value: isHovered)
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
