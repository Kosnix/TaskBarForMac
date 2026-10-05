import AppKit
import Foundation

/// Hides the real Dock entirely (`autohide`) so our panel can replace it
/// visually, one level above where the Dock itself would render (see
/// `TaskbarPanel.aboveDockLevel`).
///
/// This has bounced between two mechanisms: plain `autohide` (macOS fully
/// reclaims the Dock's space once it's hidden, so other apps' maximized
/// windows can render underneath our panel instead of stopping above it)
/// and shrinking the Dock's tile size instead (keeps the space reservation,
/// at the cost of the real Dock being shrunk-but-present rather than
/// genuinely off-screen — which turned out to let its native icon-hover
/// tooltips float above our panel, since a *running* app always gets a Dock
/// icon no matter what `persistent-apps`/`static-only` say, and Dock's own
/// hover tracking isn't blocked by our panel sitting visually on top of it).
/// Plain `autohide` wins now: it's the only way to make the real Dock
/// genuinely produce zero icons and zero tooltips, and the windows-under-
/// the-bar tradeoff is instead handled by `WindowManager.reclaimReservedSpace`,
/// which nudges any window that dips into our panel's area back above it.
final class DockController {
    private let dockDomain = "com.apple.dock" as CFString

    private struct Snapshot: Codable {
        var autohideExists: Bool
        var autohide: Bool
        var autohideDelayExists: Bool
        var autohideDelay: Double
        var autohideTimeModifierExists: Bool
        var autohideTimeModifier: Double
    }

    private let defaults = UserDefaults.standard
    private let snapshotKey = "TB.dock.snapshotV5"
    private let isActiveFlagKey = "TB.dock.isCurrentlyHiddenV5"

    /// The screen the real Dock (and therefore our panel) lives on: the one
    /// that owns the menu bar — `NSScreen.screens.first`, not necessarily
    /// `NSScreen.main` (which follows key-window focus).
    static var dockScreen: NSScreen? { NSScreen.screens.first }

    /// If a previous run left the Dock modified (crash / force-quit before
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

    /// Reads and remembers the Dock's current `autohide` settings the first
    /// time this runs in a session, then turns autohide on so the real Dock
    /// stays genuinely off-screen (and produces no icons/tooltips) while our
    /// panel is up.
    func reserveDockSpace() {
        if !defaults.bool(forKey: isActiveFlagKey) {
            captureSnapshot()
        }
        setValue(true as CFBoolean, for: "autohide")
        applyAndRestartDock()
        defaults.set(true, forKey: isActiveFlagKey)
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

        restore(snapshot.autohideExists, snapshot.autohide as CFBoolean, for: "autohide")
        restore(snapshot.autohideDelayExists, snapshot.autohideDelay as CFNumber, for: "autohide-delay")
        restore(snapshot.autohideTimeModifierExists, snapshot.autohideTimeModifier as CFNumber, for: "autohide-time-modifier")
        applyAndRestartDock()
    }

    // MARK: - CFPreferences plumbing

    private func restore(_ exists: Bool, _ value: CFPropertyList, for key: String) {
        if exists {
            setValue(value, for: key)
        } else {
            removeValue(for: key)
        }
    }

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
