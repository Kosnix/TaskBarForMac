import AppKit

/// Leftover of the removed "wallpaper that matches the theme" option: puts the
/// desktop pictures it had replaced back (a no-op for anyone who never used it).
@MainActor
enum WallpaperStore {
    private static let originalsKey = "TB.wallpaper.originals"

    static func restoreOriginals() {
        guard let originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] else { return }
        for screen in NSScreen.screens {
            if let id = screen.displayID, let path = originals[String(id)] {
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
            }
        }
        UserDefaults.standard.removeObject(forKey: originalsKey)
    }
}
