import AppKit

/// The taskbar's right-click menu — deliberately small now: every actual
/// setting lives in `SettingsWindow`, a real separate window, instead of
/// being a control embedded in this menu (see that file's history for why
/// a `Slider` specifically never worked reliably as a context-menu row).
/// This just offers a way in, plus the one thing that still makes sense as
/// an instant, no-window action.
enum PersonalizationMenuBuilder {
    static func build(themeStore: ThemeStore, windowManager: WindowManager? = nil) -> NSMenu {
        let menu = NSMenu()

        // Windows' "Task Manager" entry in the taskbar's right-click menu.
        menu.addItem(ClosureMenuItem(title: L("menu.activity_monitor")) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        })
        menu.addItem(ClosureMenuItem(title: L("menu.settings")) {
            SettingsWindowManager.show(themeStore: themeStore)
        })
        if let windowManager {
            menu.addItem(ClosureMenuItem(title: L("menu.edit_icons")) {
                windowManager.isEditingIcons = true
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("menu.quit")) {
            NSApp.terminate(nil)
        })

        return menu
    }
}
