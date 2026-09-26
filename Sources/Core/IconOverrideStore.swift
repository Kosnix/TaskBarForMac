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

    private static func fileURL(for bundleIdentifier: String) -> URL {
        // Bundle identifiers are dot-separated, never contain a literal
        // slash, but this guards against anything unexpected ending up as
        // a path component anyway.
        let safeName = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safeName).appendingPathExtension("png")
    }

    static func customIcon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        let url = fileURL(for: bundleIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func setCustomIcon(_ image: NSImage, for bundleIdentifier: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: fileURL(for: bundleIdentifier))
    }

    static func removeCustomIcon(for bundleIdentifier: String) {
        try? FileManager.default.removeItem(at: fileURL(for: bundleIdentifier))
    }
}
