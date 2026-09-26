import SwiftUI

/// A `ScrollView` wrapper that just hides the native scroll indicator —
/// three separate attempts at an actually themed (accent-colored)
/// scrollbar were all reverted after visual bugs (an `NSScroller` subclass
/// hit real AppKit fragility; a pure-SwiftUI capsule overlay tracking
/// scroll position rendered as a broken, oversized bar). The final call was
/// to leave scrolling native and just not show the default indicator.
///
/// Kept as a named wrapper (not inlined at each call site) only so each
/// start menu's existing `ScrollViewReader { proxy in … }` keyboard-nav
/// auto-scroll wiring didn't need to change shape.
struct ThemedScrollView<Content: View>: View {
    let proxy: ScrollViewProxy
    let accentColor: Color
    let itemIDs: [String]
    let content: () -> Content

    var body: some View {
        ScrollView {
            content()
        }
        .scrollIndicators(.hidden)
    }
}
