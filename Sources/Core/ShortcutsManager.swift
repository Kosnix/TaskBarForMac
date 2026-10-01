import AppKit

/// Global keyboard shortcuts, implemented with `NSEvent` global/local
/// monitors rather than a third-party dependency: this needs no compiler
/// macro plugins, so it stays buildable with plain `swift build` (no Xcode
/// required). Requires Accessibility trust — the same permission
/// `WindowManager` already needs — to see key events from other apps.
///
/// The start menu toggles on two independent, user-configurable triggers
/// (see `themeStore.startMenuTriggerModifier`/`startMenuCustomShortcut`,
/// set from Settings): a single modifier tapped alone and released quickly
/// (like Meta/Win on KDE/Windows — there's no literal Super key on a Mac
/// keyboard), and/or a full key combination. Either can be turned off
/// independently (`.none` for the modifier, `nil` for the combo).
///
/// Fixed, not configurable: ⌘⌥D = minimize all, ⌘⌥1…9 = focus the Nth
/// window.
final class ShortcutsManager {
    private let windowManager: WindowManager
    private let startMenuState: StartMenuState
    private let themeStore: ThemeStore
    private var onToggleStartMenu: (() -> Void)?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    private static let requiredModifiers: NSEvent.ModifierFlags = [.command, .option]

    /// macOS virtual key codes (US ANSI layout) for the keys we bind.
    private enum KeyCode {
        static let d: UInt16 = 0x02
        static let escape: UInt16 = 0x35
        static let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19] // 1...9
    }

    // MARK: - "solo modifier tap" detection

    /// When the configured trigger modifier went down, and whether
    /// anything else (another modifier, a regular key) happened while it
    /// was held — a solo tap only counts if nothing else was combined with
    /// it.
    private var triggerModifierDownAt: Date?
    private var triggerModifierWasCombined = false

    init(windowManager: WindowManager, startMenuState: StartMenuState, themeStore: ThemeStore) {
        self.windowManager = windowManager
        self.startMenuState = startMenuState
        self.themeStore = themeStore
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
        // Any regular key press while the trigger modifier is held
        // disqualifies it from being a "solo tap" once released — checked
        // two independent ways, not just one. `triggerModifierDownAt` is
        // set by a *separate* `flagsChanged` monitor; relying on that alone
        // assumes its event always arrives, and is processed, strictly
        // before this `keyDown`'s — true in practice almost always, but a
        // real combo slipping through on the rare time it isn't (⌘C
        // launching the start menu, reported from live use) is exactly the
        // failure mode this exists to rule out entirely. This event's own
        // `modifierFlags` says whether the trigger modifier is down *right
        // now*, independent of that other stream, so checking it here
        // directly can't miss a combo just because the two monitors
        // happened to deliver out of order.
        if triggerModifierDownAt != nil {
            triggerModifierWasCombined = true
        }
        if let triggerModifier = themeStore.startMenuTriggerModifier.modifierFlag,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(triggerModifier) {
            triggerModifierWasCombined = true
            if triggerModifierDownAt == nil {
                // The `flagsChanged` monitor hasn't (yet, or ever will for
                // this press) recorded the modifier going down — without
                // this, the later release in `handleFlagsChanged` would see
                // `triggerModifierDownAt == nil` and skip the "was it
                // combined" check entirely, rather than just skip the
                // toggle, which matters if it ever *does* see a down
                // transition afterward from some other key still held.
                triggerModifierDownAt = Date()
            }
        }

        // No modifier needed — plain Escape, only while the icon-edit
        // "jiggle" mode (see `WindowManager.isEditingIcons`) is actually on,
        // so this never swallows an Escape meant for something else.
        if event.keyCode == KeyCode.escape, windowManager.isEditingIcons {
            windowManager.isEditingIcons = false
            return true
        }

        // Same idea for Launchpad's own, separate jiggle mode — one Escape
        // stops the wiggling first, a second one (now falling through to
        // the check below) actually closes the menu, matching how the
        // taskbar's own edit mode and the menu itself are two distinct
        // things to back out of.
        if event.keyCode == KeyCode.escape, startMenuState.isEditingLaunchpad {
            startMenuState.isEditingLaunchpad = false
            return true
        }

        // Every other start menu style closes on an outside click (see
        // `StartMenuState.startWatchingForOutsideClicks`); Launchpad covers
        // the whole screen, so there's no "outside" left to click — Escape
        // is its only way to close without launching something. Handled
        // for every style here too, not just Launchpad, since it's a
        // reasonable expectation regardless.
        if event.keyCode == KeyCode.escape, startMenuState.isPresented {
            startMenuState.isPresented = false
            return true
        }

        let activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if let shortcut = themeStore.startMenuCustomShortcut,
           activeModifiers == shortcut.modifiers, event.keyCode == shortcut.keyCode {
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
        guard let triggerModifier = themeStore.startMenuTriggerModifier.modifierFlag else {
            // Disabled in Settings — still clear any in-progress tracking
            // in case it was turned off mid-press.
            triggerModifierDownAt = nil
            triggerModifierWasCombined = false
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isModifierDown = flags.contains(triggerModifier)
        let isModifierOnly = flags == triggerModifier

        if isModifierDown {
            if triggerModifierDownAt == nil {
                triggerModifierDownAt = Date()
                triggerModifierWasCombined = !isModifierOnly
            } else if !isModifierOnly {
                // Another modifier joined while the trigger one was already
                // down.
                triggerModifierWasCombined = true
            }
        } else if let downAt = triggerModifierDownAt {
            // The trigger modifier was just released.
            let heldDuration = Date().timeIntervalSince(downAt)
            if !triggerModifierWasCombined && heldDuration < 0.6 {
                onToggleStartMenu?()
            }
            triggerModifierDownAt = nil
            triggerModifierWasCombined = false
        }
    }

    deinit {
        stop()
    }
}
