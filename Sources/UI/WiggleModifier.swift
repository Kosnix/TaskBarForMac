import SwiftUI

/// The iOS springboard "jiggle" look, applied while `WindowManager.isEditingIcons`
/// is on. Driven by `TimelineView(.animation)` rather than a `@State` angle
/// ticked by `withAnimation(.repeatForever)` — a continuously-looping
/// animation normally needs somewhere to store its current phase, and
/// `@State` isn't available in this project (its modern implementation is
/// a compiler macro whose plugin isn't loadable by plain `swift build`; see
/// `ShortcutsManager`'s doc comment). `TimelineView` sidesteps that
/// entirely: it re-invokes its content with the current date on every
/// frame, so the oscillation is just computed fresh each time from
/// `context.date` — no persisted state needed at all.
private struct WiggleModifier: ViewModifier {
    let isActive: Bool
    /// Offsets each icon's phase by a little so a whole row doesn't wiggle
    /// in perfect lockstep, matching the slightly-staggered look real
    /// springboard icons have.
    let seed: Int

    /// Full rotation cycle, in seconds — fast and slightly irregular is
    /// what actually reads as "jiggling" rather than a slow, gentle sway.
    private static let cycleDuration: Double = 0.4
    private static let amplitude: Double = 5.5

    func body(content: Content) -> some View {
        if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let angularFrequency = 2 * Double.pi / Self.cycleDuration
                let phaseOffset = Double(seed % 100) * 0.31
                let t = context.date.timeIntervalSinceReferenceDate * angularFrequency + phaseOffset
                content
                    .rotationEffect(.degrees(sin(t) * Self.amplitude))
                    .offset(x: sin(t * 0.5) * 0.6, y: 0)
            }
        } else {
            content
        }
    }
}

extension View {
    func wiggle(isActive: Bool, seed: Int) -> some View {
        modifier(WiggleModifier(isActive: isActive, seed: seed))
    }
}
