import AppKit
import SwiftUI

/// Which direction a page flip goes — shared between this scroll pager and
/// `LaunchpadStartMenuView`'s own edge-hover-during-drag page flipping (see
/// its `LaunchpadEdgeDropDelegate`).
enum LaunchpadEdge {
    case previous, next
}

/// A plain mouse wheel's vertical nudge flips pages — the one case
/// `pagedGrid`'s own native `ScrollView(.horizontal)` can't handle itself,
/// since a horizontal scroll view only responds to horizontal scroll input
/// (a trackpad's two-finger swipe) by default, not a vertical wheel tick.
/// A trackpad swipe is deliberately *not* handled here at all — `hitTest`
/// only claims vertical-dominant scroll events, letting a horizontal one
/// pass straight through to that `ScrollView`, which already gives it
/// proper live 1:1 finger tracking and paging-aware settling; claiming it
/// here too would just fight the ScrollView for the same gesture and lose
/// that.
private final class ScrollPagerView: NSView {
    var onPageChange: ((LaunchpadEdge) -> Void)?

    private var accumulated: CGFloat = 0
    /// Latched the instant one flip fires, so the rest of that same wheel
    /// spin can't cross the threshold a second time and skip straight past
    /// the next page.
    private var hasFlippedThisGesture = false
    private var pendingIdleReset: DispatchWorkItem?

    private static let threshold: CGFloat = 40
    /// How long without a new scroll event before the current wheel spin
    /// counts as over and the latch above clears — deliberate individual
    /// wheel ticks are naturally spaced further apart than this.
    private static let idleResetDelay: TimeInterval = 0.15

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .scrollWheel else { return nil }
        guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        pendingIdleReset?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.accumulated = 0
            self?.hasFlippedThisGesture = false
        }
        pendingIdleReset = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleResetDelay, execute: workItem)

        guard !hasFlippedThisGesture else { return }

        accumulated += event.scrollingDeltaY
        if accumulated > Self.threshold {
            onPageChange?(.previous)
            hasFlippedThisGesture = true
        } else if accumulated < -Self.threshold {
            onPageChange?(.next)
            hasFlippedThisGesture = true
        }
    }
}

private struct LaunchpadScrollPagerRepresentable: NSViewRepresentable {
    let onPageChange: (LaunchpadEdge) -> Void

    func makeNSView(context: Context) -> ScrollPagerView {
        let view = ScrollPagerView()
        view.onPageChange = onPageChange
        return view
    }

    func updateNSView(_ nsView: ScrollPagerView, context: Context) {
        nsView.onPageChange = onPageChange
    }
}

extension View {
    /// Overlays the mouse-wheel-only page flipper described above. Layer
    /// this *under* the icons (as a `.background`, not `.overlay`) so it
    /// never sits on top of anything else hit-testable — it only ever
    /// claims vertical scroll events regardless of stacking order, but
    /// keeping it in the background is the least surprising place for it.
    func launchpadScrollPager(onPageChange: @escaping (LaunchpadEdge) -> Void) -> some View {
        background(LaunchpadScrollPagerRepresentable(onPageChange: onPageChange))
    }
}
