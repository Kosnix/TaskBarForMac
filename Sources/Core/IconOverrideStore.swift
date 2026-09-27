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
            .appendingPathComponent("TaskBarForMac", isDirectory: true)
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
        let padded = insetToMatchSystemIconPadding(image)
        cache[bundleIdentifier] = padded
        return padded
    }

    /// Real macOS app icons (`.icns`) reserve a real margin of transparent
    /// space around their actual glyph — Apple's own icon template keeps
    /// the visible artwork to roughly 80% of the canvas — which is why a
    /// picture the user picks here, filling its own canvas edge to edge,
    /// used to render visibly larger than every other icon at the same
    /// `iconSize` frame even though the frame itself was identical. Insets
    /// it (preserving aspect ratio, not stretching) to match that
    /// convention. Applied here at load time rather than once at save
    /// time, so it also fixes any icon already assigned before this
    /// existed, without needing it reassigned.
    private static func insetToMatchSystemIconPadding(_ image: NSImage) -> NSImage {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }
        let canvasDimension = max(originalSize.width, originalSize.height)
        let fillRatio: CGFloat = 0.82
        let scale = (canvasDimension * fillRatio) / canvasDimension
        let drawnSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
        let origin = NSPoint(x: (canvasDimension - drawnSize.width) / 2, y: (canvasDimension - drawnSize.height) / 2)

        let result = NSImage(size: NSSize(width: canvasDimension, height: canvasDimension))
        result.lockFocus()
        image.draw(in: NSRect(origin: origin, size: drawnSize), from: .zero, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        return result
    }

    static func setCustomIcon(_ image: NSImage, for bundleIdentifier: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: fileURL(for: bundleIdentifier))
        // Cache the same padded version `customIcon(for:)` would hand back
        // after a fresh load from disk — otherwise the icon just picked
        // would show oversized until some other cache invalidation forced
        // a re-read.
        cache[bundleIdentifier] = insetToMatchSystemIconPadding(image)
    }

    static func removeCustomIcon(for bundleIdentifier: String) {
        try? FileManager.default.removeItem(at: fileURL(for: bundleIdentifier))
        cache[bundleIdentifier] = nil
    }
}
