import AppKit

/// Custom icons assigned while "wiggling" (long-press to edit, see
/// `WindowManager.isEditingIcons`) — stored as plain PNG files under
/// Application Support, keyed by bundle identifier, so an override
/// persists across relaunches and applies everywhere that app's icon is
/// drawn (taskbar, launcher, grouped button — wherever `WindowManager`'s
/// own icon resolution is used instead of reading `NSWorkspace`/the app's
/// own bundle icon directly).
enum IconOverrideStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskbarReplacement", isDirectory: true)
            .appendingPathComponent("CustomIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// `customIcon(for:)` is read on every hover-state change (see
    /// `WindowManager.resolvedIcon`), same as `PinnedApp.icon` used to be —
    /// without this cache, `NSImage(contentsOf:)` would hand back a fresh
    /// image instance loaded from disk each time, swapping the icon's
    /// identity right as the hover-zoom animation starts and causing the
    /// same flicker that `PinnedApp.icon` had.
    private static var cache: [String: NSImage] = [:]

    private static func fileURL(for bundleIdentifier: String) -> URL {
        // Bundle identifiers are dot-separated, never contain a literal
        // slash, but this guards against anything unexpected ending up as
        // a path component anyway.
        let safeName = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safeName).appendingPathExtension("png")
    }

    static func customIcon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let cached = cache[bundleIdentifier] { return cached }
        let url = fileURL(for: bundleIdentifier)
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else { return nil }
        cache[bundleIdentifier] = image
        return image
    }

    static func setCustomIcon(_ image: NSImage, for bundleIdentifier: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: fileURL(for: bundleIdentifier))
        cache[bundleIdentifier] = image
    }

    static func removeCustomIcon(for bundleIdentifier: String) {
        try? FileManager.default.removeItem(at: fileURL(for: bundleIdentifier))
        cache[bundleIdentifier] = nil
    }
}
