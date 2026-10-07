import AppKit
import SwiftUI

/// The small floating panels the taskbar opens above itself on click — the
/// calendar over the clock, the system panel over the notification area.
/// Real windows for the same reason as `GroupHoverPanel`/`StartMenuPanel`:
/// the bar's own window is exactly its height, so nothing can draw above it.
/// One popup at a time; clicking anywhere else (or the same anchor again)
/// closes it.
@MainActor
final class BarPopups {
    static let shared = BarPopups()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private var kind: String?
    private var anchor = NSRect.zero
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Opens `content` above `anchor` (a rect in screen coordinates, the
    /// clicked element on the bar) — or closes it if that same popup is
    /// already showing.
    func toggle<Content: View>(kind: String, anchor: NSRect, barTop: CGFloat, themeStore: ThemeStore, @ViewBuilder content: () -> Content) {
        if self.kind == kind {
            close()
            return
        }
        close()
        guard let tokens = themeStore.activeTheme?.tokens else { return }

        let root = content()
            .environment(\.locale, Localization.effectiveLocale)
            .background(PanelBackground(tokens: tokens, liquidGlassEnabled: themeStore.liquidGlassEnabled, liquidGlassIntensity: themeStore.liquidGlassIntensity, showTopBorder: false))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: tokens.colors.textSecondary).opacity(0.25), lineWidth: 1))
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize

        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(kCGDockWindowLevel) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting

        // Right-aligned with the element that opened it (both live at the
        // right end of the bar), kept fully on its screen.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let frame = screen?.frame ?? anchor
        let x = min(max(anchor.maxX - size.width, frame.minX + 6), frame.maxX - size.width - 6)
        panel.setFrame(NSRect(x: x, y: barTop + 6, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.kind = kind
        self.anchor = anchor
        installMonitors()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        kind = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        // Clicks in other apps.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        // Clicks in this app's own windows (the bar itself): anything but
        // the popup and its own anchor, which handles its click itself.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
            if event.window !== panel && !self.anchor.contains(point) {
                self.close()
            }
            return event
        }
    }
}

/// An invisible click target laid over a bar element: reports the element's
/// rect in screen coordinates (and the top edge of the bar it sits on),
/// which is what `BarPopups` positions against — so it works on any screen
/// without the bar having to publish frames anywhere.
private final class PopupAnchorView: NSView {
    var onClick: ((NSRect, CGFloat) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .leftMouseDown ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onClick?(window.convertToScreen(convert(bounds, to: nil)), window.frame.maxY)
    }
}

private struct PopupAnchor: NSViewRepresentable {
    let onClick: (NSRect, CGFloat) -> Void

    func makeNSView(context: Context) -> PopupAnchorView {
        let view = PopupAnchorView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: PopupAnchorView, context: Context) {
        nsView.onClick = onClick
    }
}

extension View {
    /// Makes this bar element open a popup (see `BarPopups`) when clicked.
    func opensBarPopup<Content: View>(_ kind: String, themeStore: ThemeStore, @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay(PopupAnchor { anchor, barTop in
            BarPopups.shared.toggle(kind: kind, anchor: anchor, barTop: barTop, themeStore: themeStore, content: content)
        })
    }
}
