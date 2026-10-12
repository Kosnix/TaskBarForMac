import AppKit

/// Folder shortcuts, System Settings and the power menu shared by the
/// Windows-style start menus (XP, 7, 10, 11).
enum StartMenuShortcuts {
    enum Folder: String {
        case documents = "Documents", pictures = "Pictures", music = "Music", downloads = "Downloads", trash = ".Trash", home = ""
    }

    static func open(_ folder: Folder) {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder.rawValue))
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
    }

    /// Lock / sleep / restart always; log out and shut down only for menus
    /// that don't already have a button for them.
    static func sessionMenu(logout: Bool = true, shutdown: Bool = true) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L("session.lock"), handler: SessionManager.lockScreen))
        menu.addItem(ClosureMenuItem(title: L("session.sleep"), handler: SessionManager.sleep))
        menu.addItem(.separator())
        if logout { menu.addItem(ClosureMenuItem(title: L("session.logout"), handler: SessionManager.logOut)) }
        menu.addItem(ClosureMenuItem(title: L("session.restart"), handler: SessionManager.restart))
        if shutdown { menu.addItem(ClosureMenuItem(title: L("session.shutdown"), handler: SessionManager.shutDown)) }
        return menu
    }
}
