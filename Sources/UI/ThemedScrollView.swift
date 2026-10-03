import SwiftUI

/// One cell of a start-menu app list. Normally a list is just one copy of
/// its apps (`copy == LoopList.middleCopy`); in infinite-scroll mode it's
/// three identical copies stacked, so there's always more of the same list
/// above and below wherever you are (see `ThemedScrollView`).
struct LoopEntry<Item>: Identifiable {
    let copy: Int
    let slot: Int
    /// `nil` is a blank filler cell padding a copy out to a whole number of
    /// grid rows — without it the next copy's first app would start
    /// mid-row, in a different column than the same app in the previous
    /// copy, and jumping between copies would visibly reshuffle the grid.
    let item: Item?
    var id: String { LoopList.id(copy: copy, slot: slot) }
}

enum LoopList {
    static let copies = 3
    static let middleCopy = 1

    static func id(copy: Int, slot: Int) -> String { "\(copy)|\(slot)" }

    private static func parse(_ id: String) -> (copy: Int, slot: Int)? {
        let parts = id.split(separator: "|")
        guard parts.count == 2, let copy = Int(parts[0]), let slot = Int(parts[1]) else { return nil }
        return (copy, slot)
    }

    /// The same slot, in the middle copy — where scrolling gets quietly
    /// moved back to whenever it drifts into the first or last copy.
    static func recentered(_ id: String) -> String {
        guard let (copy, slot) = parse(id), copy != middleCopy else { return id }
        return Self.id(copy: middleCopy, slot: slot)
    }

    /// Only worth looping a list that's actually longer than what's on
    /// screen — a short one would just show itself repeated.
    static func shouldLoop(enabled: Bool, searching: Bool, count: Int, columns: Int, visibleRows: Int) -> Bool {
        enabled && !searching && count > columns * visibleRows
    }

    static func entries<Item>(_ items: [Item], columns: Int, loops: Bool) -> [LoopEntry<Item>] {
        guard loops, !items.isEmpty else {
            return items.enumerated().map { LoopEntry(copy: middleCopy, slot: $0.offset, item: $0.element) }
        }
        let perCopy = (items.count + columns - 1) / columns * columns
        return (0..<copies).flatMap { copy in
            (0..<perCopy).map { LoopEntry(copy: copy, slot: $0, item: $0 < items.count ? items[$0] : nil) }
        }
    }
}

/// A `ScrollView` wrapper that just hides the native scroll indicator —
/// three separate attempts at an actually themed (accent-colored)
/// scrollbar were all reverted after visual bugs (an `NSScroller` subclass
/// hit real AppKit fragility; a pure-SwiftUI capsule overlay tracking
/// scroll position rendered as a broken, oversized bar). The final call was
/// to leave scrolling native and just not show the default indicator.
///
/// Kept as a named wrapper (not inlined at each call site) so each start
/// menu's existing `ScrollViewReader { proxy in … }` keyboard-nav
/// auto-scroll wiring didn't need to change shape — and now also where
/// infinite scroll lives: with `loops` on, the content (built from
/// `LoopList.entries`, with `.scrollTargetLayout()` on its container) is
/// three copies of the list, scrolling starts in the middle one, and
/// whenever the top-most visible cell is in the first or last copy,
/// scrolling is moved to the *same* cell in the middle copy — identical
/// content, so the jump isn't visible and the list never runs out.
struct ThemedScrollView<Content: View>: View {
    let proxy: ScrollViewProxy
    let accentColor: Color
    let itemIDs: [String]
    /// `.hidden` still lets macOS show a scroller when the system's "Show
    /// scroll bars: Always" preference is set; `.never` doesn't — no scroll
    /// bar anywhere in the app, so this is the default.
    var indicators: ScrollIndicatorVisibility = .never
    var state: StartMenuState?
    var loops = false
    let content: () -> Content

    var body: some View {
        if loops, let state {
            // Not `@Observable`-tracked on purpose (`@ObservationIgnored` on
            // the state side): this changes on every scroll tick, and
            // tracking it would re-run `content()` — rebuilding every cell —
            // each time.
            let _ = Self.ensureStartPosition(state)
            ScrollView { content() }
                .scrollIndicators(indicators)
                .scrollPosition(id: Binding(
                    get: { state.loopScrollTopID },
                    set: { id in
                        state.loopScrollTopID = id
                        // The binding's value alone doesn't move the view (it
                        // isn't observed, see above), so jump explicitly.
                        guard let id else { return }
                        let home = LoopList.recentered(id)
                        if home != id {
                            state.loopScrollTopID = home
                            DispatchQueue.main.async { proxy.scrollTo(home, anchor: .top) }
                        }
                    }
                ))
        } else {
            let _ = Self.clearPosition(state)
            ScrollView { content() }
                .scrollIndicators(indicators)
        }
    }

    private static func ensureStartPosition(_ state: StartMenuState) {
        if state.loopScrollTopID == nil {
            state.loopScrollTopID = LoopList.id(copy: LoopList.middleCopy, slot: 0)
        }
    }

    private static func clearPosition(_ state: StartMenuState?) {
        if let state, state.loopScrollTopID != nil { state.loopScrollTopID = nil }
    }
}
