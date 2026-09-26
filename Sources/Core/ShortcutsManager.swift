import AppKit

/// Global keyboard shortcuts, implemented with `NSEvent` global/local
/// monitors rather than a third-party dependency: this needs no compiler
/// macro plugins, so it stays buildable with plain `swift build` (no Xcode
/// required). Requires Accessibility trust — the same permission
/// `WindowManager` already needs — to see key events from other apps.
///
/// Defaults: ⌘ alone = toggle start menu (like Meta/Win on
/// KDE/Windows — there's no literal Super key on a Mac keyboard, so ⌘ is
/// the closest analog), ⌘⌥D = minimize all, ⌘⌥1…9 = focus the Nth window.
///
/// The start-menu toggle also answers to ⌃⌥Space rather than ⌘⌥Space:
/// that combination is macOS's own default systemwide shortcut for
/// "Show Finder search window", and an `NSEvent` global monitor can only
/// *observe* a keystroke, never consume it — so binding ⌘⌥Space here
/// left every toggle opening a real Finder search window right alongside
/// our own menu, with no way for this monitor-based approach to stop it.
/// ⌃⌥Space isn't claimed by any macOS default shortcut.
final class ShortcutsManager {
    private let windowManager: WindowManager
    private var onToggleStartMenu: (() -> Void)?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    private static let requiredModifiers: NSEvent.ModifierFlags = [.command, .option]
    private static let startMenuModifiers: NSEvent.ModifierFlags = [.control, .option]

    /// macOS virtual key codes (US ANSI layout) for the keys we bind.
    private enum KeyCode {
        static let d: UInt16 = 0x02
        static let space: UInt16 = 0x31
        static let escape: UInt16 = 0x35
        static let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19] // 1...9
    }

    // MARK: - "⌘ alone" detection

    /// When ⌘ went down, and whether anything else (another modifier, a
    /// regular key) happened while it was held — a solo tap only counts if
    /// nothing else was combined with it, exactly like Meta/Win on
    /// Linux/Windows.
    private var commandDownAt: Date?
    private var commandWasCombined = false

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    func start(onToggleStartMenu: @escaping () -> Void) {
        self.onToggleStartMenu = onToggleStartMenu

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        // Also handle the case where our own panel currently has key focus
        // (e.g. the start menu's search field).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKeyDown(event) else { return event }
            return nil
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func stop() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Any regular key press while ⌘ is held disqualifies it from being
        // a "solo tap" once released (e.g. ⌘C, ⌘Tab).
        if commandDownAt != nil {
            commandWasCombined = true
        }

        // No modifier needed — plain Escape, only while the icon-edit
        // "jiggle" mode (see `WindowManager.isEditingIcons`) is actually on,
        // so this never swallows an Escape meant for something else.
        if event.keyCode == KeyCode.escape, windowManager.isEditingIcons {
            windowManager.isEditingIcons = false
            return true
        }

        let activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if activeModifiers == Self.startMenuModifiers, event.keyCode == KeyCode.space {
            onToggleStartMenu?()
            return true
        }

        guard activeModifiers == Self.requiredModifiers else {
            return false
        }

        if event.keyCode == KeyCode.d {
            windowManager.minimizeAll()
            return true
        }
        if let index = KeyCode.digits.firstIndex(of: event.keyCode) {
            windowManager.activateEntry(at: index)
            return true
        }
        return false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCommandDown = flags.contains(.command)
        let isCommandOnly = flags == .command

        if isCommandDown {
            if commandDownAt == nil {
                commandDownAt = Date()
                commandWasCombined = !isCommandOnly
            } else if !isCommandOnly {
                // Another modifier (⇧⌘, ⌥⌘…) joined while ⌘ was already down.
                commandWasCombined = true
            }
        } else if let downAt = commandDownAt {
            // ⌘ was just released.
            let heldDuration = Date().timeIntervalSince(downAt)
            if !commandWasCombined && heldDuration < 0.6 {
                onToggleStartMenu?()
            }
            commandDownAt = nil
            commandWasCombined = false
        }
    }

    deinit {
        stop()
    }
}
