import AppKit

/// Which modifier, tapped alone and released quickly (the existing ⌘-alone
/// detection in `ShortcutsManager`, generalized to any one of these instead
/// of only ⌘), toggles the start menu — `.none` turns that whole gesture
/// off, for someone who only wants the custom combo below, or neither.
enum StartMenuTriggerModifier: String, CaseIterable, Identifiable {
    case none
    case command
    case option
    case control
    case shift

    var id: String { rawValue }

    /// `nil` for `.none`, which has no modifier to watch for at all.
    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .none: return nil
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }

    /// Symbol *and* a spelled-out name — a bare "⌘"/"⌥"/"⌃"/"⇧" in a list
    /// read as nearly indistinguishable from each other (and from "nothing
    /// selected") at the small size a `Picker` row renders text at.
    var displayName: String {
        switch self {
        case .none: return L("settings.start_menu_trigger.none")
        case .command: return "⌘ " + L("settings.start_menu_trigger.command")
        case .option: return "⌥ " + L("settings.start_menu_trigger.option")
        case .control: return "⌃ " + L("settings.start_menu_trigger.control")
        case .shift: return "⇧ " + L("settings.start_menu_trigger.shift")
        }
    }
}

/// A full key combination (at least one modifier plus a key), captured by
/// `ShortcutRecorder` and checked in `ShortcutsManager` — on top of, not
/// instead of, the solo-modifier-tap trigger above; either one (or
/// neither, or both) can be active independently.
struct StartMenuShortcut: Equatable {
    var keyCode: UInt16
    /// Always masked to `.deviceIndependentFlagsMask` before being stored —
    /// comparing a live event's own modifiers (masked the same way, see
    /// `ShortcutsManager`) against this only ever needs to agree on which
    /// modifiers are logically held, not device-specific flag bits.
    var modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + Self.keyName(for: keyCode)
    }

    /// US ANSI virtual key codes for the keys someone could plausibly pick
    /// for a shortcut — a plain letter/digit/punctuation key reads back as
    /// itself, the rest by name. Falls back to the raw key code for
    /// anything exotic (a media key, say) rather than showing nothing.
    static func keyName(for keyCode: UInt16) -> String {
        if let named = namedKeys[keyCode] { return named }
        if let letter = letterKeys[keyCode] { return letter }
        return "Key \(keyCode)"
    }

    private static let letterKeys: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G",
        0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N",
        0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U",
        0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6",
        0x1A: "7", 0x1C: "8", 0x19: "9"
    ]

    private static let namedKeys: [UInt16: String] = [
        0x31: "Space", 0x24: "⏎", 0x30: "⇥", 0x33: "⌫", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
    ]
}

/// Captures the next key combination pressed anywhere (not just while this
/// app's own window has focus), the same global-monitor approach
/// `ShortcutsManager` already relies on for every other shortcut — so
/// recording doesn't need this control to become first responder across
/// the SwiftUI/AppKit bridge, which tends to be unreliable for a
/// `.nonactivatingPanel`-hosted accessory app like this one.
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    var onCapture: ((StartMenuShortcut) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let escapeKeyCode: UInt16 = 0x35

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func cancelRecording() {
        isRecording = false
        stopMonitors()
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.keyCode == Self.escapeKeyCode {
            cancelRecording()
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Requires at least one modifier — a shortcut that's just a bare
        // letter would swallow ordinary typing anywhere in the system.
        guard !modifiers.isEmpty else { return false }
        onCapture?(StartMenuShortcut(keyCode: event.keyCode, modifiers: modifiers))
        isRecording = false
        stopMonitors()
        return true
    }

    private func stopMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit {
        stopMonitors()
    }
}
