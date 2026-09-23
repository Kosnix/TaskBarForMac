import AppKit
import ApplicationServices

/// Hides the taskbar panel while any app is running in native macOS
/// fullscreen on the Dock's screen, and brings it back once fullscreen is
/// exited — matching how the real Dock and menu bar behave.
///
/// Two previous approaches didn't hold up:
/// - `CGWindowListCopyWindowInfo` for a window matching the screen's full
///   bounds only worked during the fullscreen *transition animation*: a
///   fullscreen app gets its own dedicated Space once fully engaged, and
///   `CGWindowListCopyWindowInfo` generally can't see windows on a Space
///   other than the one currently being displayed, so the check went back
///   to reporting "not fullscreen" the moment the animation settled.
/// - A menu-bar-visibility heuristic (`visibleFrame` losing its top inset)
///   looked reliable in testing but silently breaks for anyone with System
///   Settings → Control Center → "Automatically hide and show the menu bar"
///   turned on for *desktop*, not just fullscreen apps — the inset then
///   reads as zero all the time, or flickers with mouse-hover reveals,
///   independent of fullscreen state entirely.
///
/// Querying the frontmost app's focused window for `kAXFullScreenAttribute`
/// sidesteps both problems: the Accessibility API talks to the owning
/// process directly rather than the window server's per-Space window list,
/// so it works the same whether or not that Space is currently displayed,
/// and it's the same flag AppKit itself sets on a window when
/// `toggleFullScreen(_:)` runs, independent of any menu-bar setting.
final class FullscreenObserver {
    private var timer: Timer?
    private var isCurrentlyFullscreen = false
    private var pendingState: Bool?
    private var pendingCount = 0
    private var onChange: ((Bool) -> Void)?

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(check),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(check),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.check()
        }
        check()
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        timer = nil
    }

    @objc private func check() {
        let fullscreen = Self.frontmostAppIsFullscreen()
        if fullscreen == isCurrentlyFullscreen {
            pendingState = nil
            pendingCount = 0
            return
        }
        if pendingState == fullscreen {
            pendingCount += 1
        } else {
            pendingState = fullscreen
            pendingCount = 1
        }
        guard pendingCount >= 2 else { return } // one more consistent reading before committing
        isCurrentlyFullscreen = fullscreen
        pendingState = nil
        pendingCount = 0
        onChange?(fullscreen)
    }

    /// True when the frontmost application's focused (or, failing that,
    /// main) window reports itself as fullscreen via AX — the same
    /// space-independent signal regardless of which Space is on screen.
    private static func frontmostAppIsFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        // Our own panel/start menu becoming "frontmost" (e.g. right after a
        // click) should never be read as a fullscreen app.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let window = copyWindowAttribute(appElement, kAXFocusedWindowAttribute)
            ?? copyWindowAttribute(appElement, kAXMainWindowAttribute)
        guard let window else { return false }
        // Not a Carbon-era `kAX...` constant (no such symbol exists for it
        // in ApplicationServices) — "AXFullScreen" is the attribute AppKit
        // itself sets on a window's accessibility element when it's in
        // native fullscreen, used here as the same raw string.
        return copyBoolAttribute(window, "AXFullScreen") ?? false
    }

    private static func copyWindowAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? Bool
    }
}
