import AppKit
import SwiftUI

/// Thin wrapper so theme panels can opt into a real macOS blur (`blurEnabled`
/// in tokens.json) instead of a flat translucent color.
///
/// Defaults to `.withinWindow` blending: `.behindWindow` samples whatever is
/// actually behind our window at the compositor level — which, for this
/// panel, is the real (shrunk but still-present) Dock — so it would show a
/// blurred Dock through our "opaque" bar instead of hiding it. `.withinWindow`
/// blurs/vibrancy-blends against content layered behind it inside our own
/// window instead, giving a frosted look without exposing the real Dock.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    /// Pins the material's light/dark tone instead of following the
    /// system's — `nil` keeps following it.
    var appearance: NSAppearance?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.appearance = appearance
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = appearance
    }
}
