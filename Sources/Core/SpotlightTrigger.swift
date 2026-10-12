import CoreGraphics

/// Opens the real, system Spotlight search overlay — used when the start
/// menu style is set to "Spotlight" (see `ThemeStore.startMenuStyle`): that
/// mode doesn't draw any UI of its own at all, it just hands off to the
/// genuine thing.
///
/// There's no public API for this; the standard, reliable technique (also
/// how Spotlight's own global hotkey is normally invoked by anything other
/// than the keyboard itself) is a synthetic hardware-level ⌘Space key
/// event. This is a different mechanism from `SessionManager`'s AppleScript
/// "keystroke" UI-scripting, which macOS specifically blocks for the Lock
/// Screen shortcut — Spotlight's hotkey is just an ordinary, user-
/// reassignable global shortcut, not a hardened security action, so a
/// synthetic `CGEvent` reaches it the same way a real key press would.
enum SpotlightTrigger {
    private static let spaceKeyCode: CGKeyCode = 0x31

    static func open() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: spaceKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: spaceKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
