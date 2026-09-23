import AppKit

/// Session control actions for the start menu's "leave" footer
/// (lock/sleep/log out/restart/shut down).
///
/// Log out/restart/shut down go through System Events' Apple Events; the
/// first call prompts for Automation permission — expected for a taskbar
/// that offers to end the session. Lock reuses the standard macOS Lock
/// Screen shortcut (⌃⌘Q) via System Events UI scripting, which only needs
/// the Accessibility trust this app already requires for window management.
/// All three destructive actions ask for confirmation first, same as
/// Plasma's own leave dialog.
enum SessionManager {
    static func lockScreen() {
        runAppleScript(#"tell application "System Events" to keystroke "q" using {control down, command down}"#)
    }

    static func sleep() {
        runAppleScript(#"tell application "System Events" to sleep"#)
    }

    static func logOut() {
        confirmThenRun(
            title: L("session.logout_confirm.title"),
            message: L("session.confirm.message"),
            confirmTitle: L("session.logout")
        ) {
            runAppleScript(#"tell application "System Events" to log out"#)
        }
    }

    static func restart() {
        confirmThenRun(
            title: L("session.restart_confirm.title"),
            message: L("session.confirm.message"),
            confirmTitle: L("session.restart")
        ) {
            runAppleScript(#"tell application "System Events" to restart"#)
        }
    }

    static func shutDown() {
        confirmThenRun(
            title: L("session.shutdown_confirm.title"),
            message: L("session.confirm.message"),
            confirmTitle: L("session.shutdown")
        ) {
            runAppleScript(#"tell application "System Events" to shut down"#)
        }
    }

    private static func confirmThenRun(title: String, message: String, confirmTitle: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("button.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&errorDict)
        if let errorDict {
            print("[SessionManager] AppleScript error: \(errorDict)")
            return false
        }
        return true
    }
}
