import AppKit
import SwiftUI

/// The app's real preferences window — titled, closable, normal window
/// level — unlike `TaskbarPanel`/`StartMenuPanel`, which are borderless,
/// always-on-top, non-activating panels. Settings are opened deliberately
/// and should behave like any other app's Settings window: its own title
/// bar, closable, not fighting for focus with everything else.
final class SettingsWindow: NSWindow {
    init(themeStore: ThemeStore) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = L("settings.window_title")
        isReleasedWhenClosed = false
        center()
        contentView = NSHostingView(rootView: SettingsView(themeStore: themeStore))
    }
}

/// Keeps a single, reused `SettingsWindow` instance instead of creating a
/// new one every time "Paramètres…" is chosen from the right-click menu.
enum SettingsWindowManager {
    private static var window: SettingsWindow?

    static func show(themeStore: ThemeStore) {
        let target = window ?? {
            let created = SettingsWindow(themeStore: themeStore)
            window = created
            return created
        }()
        // The app runs with `.accessory` activation policy (no Dock icon),
        // which doesn't auto-activate on its own the way a normal app
        // would when a window opens — without this, the window can appear
        // behind whatever's currently frontmost instead of gaining focus.
        NSApp.activate(ignoringOtherApps: true)
        target.makeKeyAndOrderFront(nil)
    }
}
