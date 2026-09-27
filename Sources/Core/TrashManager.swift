import AppKit

/// The taskbar's trash icon right-click menu's "Empty Trash" action.
///
/// Goes through Finder's own Apple Event, not a raw `FileManager` deletion
/// of `~/.Trash`'s contents — same reasoning as `AppDiscovery.uninstall`'s
/// own doc comment: emptying the trash can require the same kind of
/// authentication a privileged item's own deletion does, which only
/// Finder (not our own process) is positioned to prompt for. Confirmed
/// first, same as every other destructive action in this app (see
/// `SessionManager`).
enum TrashManager {
    static func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = L("alert.empty_trash.title")
        alert.informativeText = L("alert.empty_trash.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("menu.empty_trash"))
        alert.addButton(withTitle: L("button.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var errorDict: NSDictionary?
        let script = NSAppleScript(source: #"tell application "Finder" to empty trash"#)
        script?.executeAndReturnError(&errorDict)
        if let errorDict {
            print("[TrashManager] AppleScript error: \(errorDict)")
        }
    }
}
