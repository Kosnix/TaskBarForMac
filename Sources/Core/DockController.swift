import AppKit
import Foundation

/// Hides the native Dock the classic way: `autohide` with an effectively
/// infinite reveal delay, so it never practically comes back on its own.
///
/// This was previously replaced with shrinking the real Dock's tile size
/// instead, so macOS kept reserving its screen space for other windows to
/// avoid (matching how a normal, visible Dock behaves) — reverted back to
/// plain `autohide` on request. The tradeoff: with the Dock's space fully
/// reclaimed by macOS, other apps' maximized/fullscreen windows can render
/// underneath our panel again. The upside that mattered more here: the Dock
/// is genuinely off-screen rather than just shrunk-but-present, so there's
/// nothing left for a translucent (Liquid Glass) panel background to show
/// through.
final class DockController {
    private let dockDomain = "com.apple.dock" as CFString

    /// Large enough that the Dock effectively never reappears on its own —
    /// the whole point of hiding it.
    private static let autohideDelaySeconds: Double = 9999

    private struct Snapshot: Codable {
        var autohideExists: Bool
        var autohide: Bool
        var autohideDelayExists: Bool
        var autohideDelay: Double
        var autohideTimeModifierExists: Bool
        var autohideTimeModifier: Double
    }

    private let defaults = UserDefaults.standard
    private let snapshotKey = "TB.dock.snapshotV3"
    private let isActiveFlagKey = "TB.dock.isCurrentlyHiddenV3"

    /// The screen the real Dock (and therefore our panel) lives on: the one
    /// that owns the menu bar — `NSScreen.screens.first`, not necessarily
    /// `NSScreen.main` (which follows key-window focus).
    static var dockScreen: NSScreen? { NSScreen.screens.first }

    /// If a previous run left the Dock hidden (crash / force-quit before
    /// `restoreDock()` ran), ask the user whether to restore it first.
    func offerRecoveryIfNeeded() {
        guard defaults.bool(forKey: isActiveFlagKey) else { return }

        let alert = NSAlert()
        alert.messageText = L("alert.dock_recovery.title")
        alert.informativeText = L("alert.dock_recovery.message")
        alert.addButton(withTitle: L("button.restore_dock"))
        alert.addButton(withTitle: L("button.continue_without_restoring"))
        if alert.runModal() == .alertFirstButtonReturn {
            restoreDock()
        }
    }

    /// Reads and remembers the Dock's current settings the first time this
    /// runs in a session, then switches it to `autohide` with a ~9999s
    /// delay before it would reappear.
    func hideDock() {
        if !defaults.bool(forKey: isActiveFlagKey) {
            captureSnapshot()
        }
        setValue(true as CFBoolean, for: "autohide")
        setValue(Self.autohideDelaySeconds as CFNumber, for: "autohide-delay")
        setValue(0.0 as CFNumber, for: "autohide-time-modifier")
        applyAndRestartDock()
        defaults.set(true, forKey: isActiveFlagKey)
    }

    /// A single, non-blocking read of how much space is currently reserved
    /// at the bottom of the Dock's screen (0 if unavailable — which is the
    /// normal state once the Dock is auto-hidden, since macOS reclaims that
    /// space).
    static func currentReservedHeight() -> CGFloat {
        guard let screen = dockScreen else { return 0 }
        return max(0, screen.visibleFrame.minY - screen.frame.minY)
    }

    func restoreDock() {
        defer {
            defaults.removeObject(forKey: isActiveFlagKey)
            defaults.removeObject(forKey: snapshotKey)
        }
        guard let snapshot = loadSnapshot() else {
            removeValue(for: "autohide")
            removeValue(for: "autohide-delay")
            removeValue(for: "autohide-time-modifier")
            applyAndRestartDock()
            return
        }

        if snapshot.autohideExists {
            setValue(snapshot.autohide as CFBoolean, for: "autohide")
        } else {
            removeValue(for: "autohide")
        }
        if snapshot.autohideDelayExists {
            setValue(snapshot.autohideDelay as CFNumber, for: "autohide-delay")
        } else {
            removeValue(for: "autohide-delay")
        }
        if snapshot.autohideTimeModifierExists {
            setValue(snapshot.autohideTimeModifier as CFNumber, for: "autohide-time-modifier")
        } else {
            removeValue(for: "autohide-time-modifier")
        }
        applyAndRestartDock()
    }

    // MARK: - CFPreferences plumbing

    private func setValue(_ value: CFPropertyList, for key: String) {
        CFPreferencesSetValue(key as CFString, value, dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func removeValue(for key: String) {
        CFPreferencesSetValue(key as CFString, nil, dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func copyValue(for key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func applyAndRestartDock() {
        CFPreferencesSynchronize(dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }

    private func captureSnapshot() {
        let autohideValue = copyValue(for: "autohide") as? Bool
        let delayValue = copyValue(for: "autohide-delay") as? Double
        let timeModifierValue = copyValue(for: "autohide-time-modifier") as? Double

        let snapshot = Snapshot(
            autohideExists: autohideValue != nil,
            autohide: autohideValue ?? false,
            autohideDelayExists: delayValue != nil,
            autohideDelay: delayValue ?? 0,
            autohideTimeModifierExists: timeModifierValue != nil,
            autohideTimeModifier: timeModifierValue ?? 1.0
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    private func loadSnapshot() -> Snapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
