import AppKit

/// `SACLockScreenImmediate` — not in any public header, but the same
/// long-standing private symbol Hammerspoon's `hs.caffeinate.lockScreen()`
/// and several other utilities call for an immediate, reliable screen
/// lock. Resolved at runtime (`dlopen`/`dlsym`, not linked at build time —
/// `login.framework` isn't a public framework this target links against),
/// since a synthetic ⌃⌘Q keystroke (the previous approach) stopped actually
/// locking the screen on recent macOS: Apple ignores synthetic keyboard
/// events for that specific shortcut as a security measure against exactly
/// this kind of scripted automation.
private typealias LockScreenFunction = @convention(c) () -> Void

private func lockScreenImmediate() -> Bool {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW) else {
        return false
    }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
        return false
    }
    unsafeBitCast(symbol, to: LockScreenFunction.self)()
    return true
}

/// Session control actions for the start menu's "leave" footer
/// (lock/sleep/log out/restart/shut down).
///
/// Log out/restart/shut down go through System Events' Apple Events; the
/// first call prompts for Automation permission — expected for a taskbar
/// that offers to end the session. Lock and sleep go through direct system
/// calls instead (no Apple Events, no Automation permission needed) — see
/// `lockScreenImmediate()` and `pmset sleepnow` below. All three
/// destructive actions ask for confirmation first, same as Plasma's own
/// leave dialog.
enum SessionManager {
    static func lockScreen() {
        guard lockScreenImmediate() else {
            // Best-effort fallback, in case a future macOS removes this
            // private symbol too — better than silently doing nothing.
            runAppleScript(#"tell application "System Events" to keystroke "q" using {control down, command down}"#)
            return
        }
    }

    static func sleep() {
        runProcess("/usr/bin/pmset", arguments: ["sleepnow"])
    }

    private static func runProcess(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
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
