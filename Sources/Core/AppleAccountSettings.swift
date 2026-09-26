import AppKit

/// Opens System Settings straight to the "Apple Account" pane — same
/// `x-apple.systempreferences:` scheme `PermissionsManager` already uses for
/// the Accessibility pane, just a different pane identifier. Used by every
/// start menu's account photo (see `StartMenuView`, `Windows7StartMenuView`,
/// `Windows11StartMenuView`).
enum AppleAccountSettings {
    static func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") else { return }
        NSWorkspace.shared.open(url)
    }
}
