import AppKit
import ApplicationServices

/// Windows' "Aero Snap": drop a window you've dragged by its title bar onto
/// a screen edge and it snaps there — left or right edge for that half of
/// the screen, the top edge to fill it, a corner for that quarter. The area
/// it fills stops at the taskbar and the menu bar.
///
/// Watches mouse buttons globally (no event interception), remembers the
/// window under the pointer at mouse-down, and on mouse-up checks whether
/// that window was moved (same size, new place) with the pointer parked at
/// an edge.
@MainActor
final class WindowSnapController {
    private let themeStore: ThemeStore
    private var monitors: [Any] = []
    private var dragged: (window: AXUIElement, origin: CGPoint, size: CGSize)?

    private static let edgeThreshold: CGFloat = 6
    private static let cornerReach: CGFloat = 110

    init(themeStore: ThemeStore) {
        self.themeStore = themeStore
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(down) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }) { monitors.append(up) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        dragged = nil
    }

    // MARK: - Events

    private func mouseDown() {
        dragged = nil
        guard let primary = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(mouse.x), Float(primary.frame.height - mouse.y), &element) == .success,
              let element, let window = Self.window(containing: element),
              let origin = Self.point(window, kAXPositionAttribute), let size = Self.size(window) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        dragged = (window, origin, size)
    }

    private func mouseUp() {
        guard let start = dragged else { return }
        dragged = nil
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
        // A real title-bar drag: the window moved and kept its size.
        guard let origin = Self.point(start.window, kAXPositionAttribute), let size = Self.size(start.window),
              hypot(origin.x - start.origin.x, origin.y - start.origin.y) > 4,
              abs(size.width - start.size.width) < 3, abs(size.height - start.size.height) < 3 else { return }
        guard let target = Self.target(for: mouse, on: screen, barHeight: themeStore.effectivePanelHeight) else { return }
        // Let the system finish its own drop handling (it has its own edge
        // tiling) before overriding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [window = start.window] in
            Self.place(window, in: target)
        }
    }

    // MARK: - Geometry

    /// The area a snapped window may fill on `screen`, in AppKit coordinates.
    private static func area(of screen: NSScreen, barHeight: CGFloat) -> CGRect {
        let bottom = screen.frame.minY + barHeight
        return CGRect(x: screen.frame.minX, y: bottom, width: screen.frame.width, height: max(100, screen.visibleFrame.maxY - bottom))
    }

    /// Which part of the screen's area the pointer's edge position asks for,
    /// or nil when it isn't at an edge.
    private static func target(for mouse: CGPoint, on screen: NSScreen, barHeight: CGFloat) -> CGRect? {
        let frame = screen.frame
        let area = area(of: screen, barHeight: barHeight)
        let atLeft = mouse.x <= frame.minX + edgeThreshold
        let atRight = mouse.x >= frame.maxX - edgeThreshold
        let atTop = mouse.y >= frame.maxY - edgeThreshold
        guard atLeft || atRight || atTop else { return nil }
        let nearTop = mouse.y >= area.maxY - cornerReach
        let nearBottom = mouse.y <= area.minY + cornerReach
        let halfWidth = area.width / 2
        let halfHeight = area.height / 2

        if atLeft || atRight {
            let x = atLeft ? area.minX : area.minX + halfWidth
            if nearTop { return CGRect(x: x, y: area.minY + halfHeight, width: halfWidth, height: halfHeight) }
            if nearBottom { return CGRect(x: x, y: area.minY, width: halfWidth, height: halfHeight) }
            return CGRect(x: x, y: area.minY, width: halfWidth, height: area.height)
        }
        // Top edge: fills the area, except right in a corner.
        if mouse.x <= frame.minX + cornerReach { return CGRect(x: area.minX, y: area.minY + halfHeight, width: halfWidth, height: halfHeight) }
        if mouse.x >= frame.maxX - cornerReach { return CGRect(x: area.minX + halfWidth, y: area.minY + halfHeight, width: halfWidth, height: halfHeight) }
        return area
    }

    private static func place(_ window: AXUIElement, in rect: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        var position = CGPoint(x: rect.minX, y: primary.frame.height - rect.maxY)
        var size = rect.size
        // Position, size, position again: some apps clamp the size to the
        // screen they were last on, or shift the window when it resizes.
        for _ in 0..<2 {
            if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
            if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        }
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
    }

    // MARK: - AX helpers

    private static func window(containing element: AXUIElement) -> AXUIElement? {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success, role as? String == kAXWindowRole as String {
            return element
        }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
