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
/// Frame times for the wiggle: forever while editing, or just until the
/// fade-out finishes (ending exactly on `endsAt`, so the icon is left
/// perfectly upright) after editing stops.
private struct WiggleSchedule: TimelineSchedule {
    let endsAt: Date?

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        let frame: TimeInterval = 1.0 / 60.0
        guard let endsAt else {
            return AnySequence(sequence(first: startDate) { $0.addingTimeInterval(frame) })
        }
        return AnySequence(Array(stride(from: startDate, to: endsAt, by: frame)) + [endsAt])
    }
}

private struct WiggleModifier: ViewModifier {
    let isActive: Bool
    /// When `isActive` last changed — the wiggle eases in (with a small
    /// pop) and out over `transitionDuration` from that moment instead of
    /// snapping on and off.
    let changedAt: Date
    /// Offsets each icon's phase by a little so a whole row doesn't wiggle
    /// in perfect lockstep, matching the slightly-staggered look real
    /// springboard icons have.
    let seed: Int

    /// Full rotation cycle, in seconds — fast and slightly irregular is
    /// what actually reads as "jiggling" rather than a slow, gentle sway.
    private static let cycleDuration: Double = 0.4
    private static let amplitude: Double = 5.5
    private static let transitionDuration: TimeInterval = 0.25
    /// How much an icon swells at the midpoint of entering edit mode.
    private static let popScale: Double = 0.08

    @ViewBuilder
    func body(content: Content) -> some View {
        let fadeEnd = changedAt.addingTimeInterval(Self.transitionDuration)
        if isActive || Date() < fadeEnd {
            TimelineView(WiggleSchedule(endsAt: isActive ? nil : fadeEnd)) { context in
                let progress = min(1, max(0, context.date.timeIntervalSince(changedAt) / Self.transitionDuration))
                let strength = isActive ? progress : 1 - progress
                let angularFrequency = 2 * Double.pi / Self.cycleDuration
                let phaseOffset = Double(seed % 100) * 0.31
                let t = context.date.timeIntervalSinceReferenceDate * angularFrequency + phaseOffset
                content
                    .rotationEffect(.degrees(sin(t) * Self.amplitude * strength))
                    .offset(x: sin(t * 0.5) * 0.6 * strength, y: 0)
                    .scaleEffect(isActive ? 1 + Self.popScale * sin(.pi * progress) : 1)
            }
        } else {
            content
        }
    }
}

extension View {
    func wiggle(isActive: Bool, since changedAt: Date, seed: Int) -> some View {
        modifier(WiggleModifier(isActive: isActive, changedAt: changedAt, seed: seed))
    }
}
