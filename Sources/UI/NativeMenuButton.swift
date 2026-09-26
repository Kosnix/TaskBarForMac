import AppKit
import SwiftUI

/// A plain icon button that pops up a real, native `NSMenu` right below
/// itself when clicked — used in place of SwiftUI's own `Menu`, which
/// always draws its own extra disclosure indicator next to a custom label
/// no matter the style (`.borderlessButton` included), producing a visibly
/// broken double-arrow look. Same reasoning as `TaskbarContainerView`'s own
/// right-click menu: a real `NSMenu` is what actually behaves the way a
/// plain icon-triggered menu should — just the icon, nothing extra bolted
/// onto it.
struct NativeMenuButton: View {
    let systemImage: String
    let size: CGFloat
    let tintColor: Color
    let makeMenu: () -> NSMenu

    var body: some View {
        NativeMenuButtonRepresentable(systemImage: systemImage, size: size, tintColor: NSColor(tintColor), makeMenu: makeMenu)
            .frame(width: size + 14, height: size + 14)
    }
}

private struct NativeMenuButtonRepresentable: NSViewRepresentable {
    let systemImage: String
    let size: CGFloat
    let tintColor: NSColor
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> ClickableMenuView {
        let view = ClickableMenuView()
        view.configure(systemImage: systemImage, size: size, tintColor: tintColor)
        view.menuProvider = makeMenu
        return view
    }

    func updateNSView(_ nsView: ClickableMenuView, context: Context) {
        nsView.configure(systemImage: systemImage, size: size, tintColor: tintColor)
        nsView.menuProvider = makeMenu
    }
}

final class ClickableMenuView: NSView {
    var menuProvider: (() -> NSMenu)?
    private let imageView = NSImageView()
    private var sizeConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(systemImage: String, size: CGFloat, tintColor: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        imageView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        imageView.contentTintColor = tintColor
        if sizeConstraints.isEmpty {
            sizeConstraints = [
                imageView.widthAnchor.constraint(equalToConstant: size),
                imageView.heightAnchor.constraint(equalToConstant: size)
            ]
            NSLayoutConstraint.activate(sizeConstraints)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
