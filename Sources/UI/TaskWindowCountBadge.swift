import SwiftUI

/// The small notification-style badge both `TaskButtonView` (a single
/// *minimized* window — `.empty`, since there's nothing meaningful to
/// count, just something to flag) and `GroupedTaskButtonView` (2+ windows,
/// always `.count(windows.count)`) pin to their icon's own bottom-trailing
/// corner, tinted with the active theme's own accent color rather than a
/// fixed red — matching how every other "something's active/selected"
/// indicator in this app (the active-window underline, hover states)
/// already reads from the theme instead of a hardcoded color.
struct TaskWindowCountBadge: View {
    enum Style {
        /// A single minimized window — just a plain colored dot, no "1":
        /// there's nothing to actually count here, so a number would only
        /// ever read as a count of windows, which is misleading once
        /// that's the whole point of the badge in the grouped case too.
        case empty
        /// `Capsule` rather than a fixed circle so it still reads correctly
        /// past single digits (10, 100…), matching how iOS's own badge
        /// stretches horizontally instead of shrinking its text to fit.
        case count(Int)
    }

    let style: Style
    let accentColor: Color

    static let diameter: CGFloat = 15
    static let emptyDiameter: CGFloat = 10
    // `TaskbarView.centerZone` deliberately `.clipped()`s the whole task
    // list to its exact panel height (so overflowing content can't paint
    // into the neighboring zone) — pushing the badge *past* the icon's own
    // corner with a positive offset overhangs it past that same clipped
    // edge too, truncating it, since a compact panel/icon size can leave
    // little to no vertical slack below the icon. Anchoring flush with the
    // corner (no push) keeps the whole badge inside the icon's own square,
    // which is guaranteed not to clip since the icon itself already
    // renders there without being cut off.
    static let edgeOffset: CGFloat = 0

    var body: some View {
        switch style {
        case .empty:
            Circle()
                .fill(accentColor)
                .frame(width: Self.emptyDiameter, height: Self.emptyDiameter)
        case .count(let count):
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(minWidth: Self.diameter, minHeight: Self.diameter)
                .background(accentColor, in: Capsule())
        }
    }
}

extension View {
    /// Pins the badge to this icon's own bottom-trailing corner, riding
    /// along with whatever transform (`.hoverLift`'s scale, `.wiggle`'s
    /// jitter) the icon itself already has — real iOS/Launchpad badges are
    /// drawn as part of the icon, not the surrounding button, so this
    /// attaches directly to the icon `Image` at each call site rather than
    /// being hand-positioned off the button's own edge the way the old
    /// minimized dot this replaces used to be. `nil` shows nothing.
    @ViewBuilder
    func taskWindowCountBadge(_ style: TaskWindowCountBadge.Style?, accentColor: Color) -> some View {
        if let style {
            overlay(alignment: .bottomTrailing) {
                TaskWindowCountBadge(style: style, accentColor: accentColor)
                    .offset(x: TaskWindowCountBadge.edgeOffset, y: TaskWindowCountBadge.edgeOffset)
            }
        } else {
            self
        }
    }
}
