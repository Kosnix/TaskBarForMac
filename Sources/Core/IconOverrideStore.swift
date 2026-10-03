import AppKit
import SwiftUI

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
        let padded = shapedLikeSystemIcon(image)
        cache[bundleIdentifier] = padded
        return padded
    }

    /// Makes a picked picture look like a real macOS app icon: scaled to
    /// fill the same inset square system icons occupy — Apple's own icon
    /// template keeps the visible artwork to roughly 80% of the canvas,
    /// which is why a picture filling its canvas edge to edge used to render
    /// visibly larger than every other icon at the same `iconSize` frame —
    /// and clipped to macOS's rounded "squircle" outline instead of
    /// keeping a picture's own square (or arbitrary) corners. Applied here
    /// at load time rather than once at save time, so it also fixes any
    /// icon already assigned before this existed, without needing it
    /// reassigned.
    private static func shapedLikeSystemIcon(_ image: NSImage) -> NSImage {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }
        let canvasDimension = max(originalSize.width, originalSize.height)
        let bodyDimension = canvasDimension * 0.82
        let bodyRect = NSRect(
            x: (canvasDimension - bodyDimension) / 2,
            y: (canvasDimension - bodyDimension) / 2,
            width: bodyDimension,
            height: bodyDimension
        )
        // Aspect-fill (cropping the overflow) rather than aspect-fit: a
        // non-square picture left transparent bars inside the outline,
        // which no real app icon has.
        let scale = max(bodyDimension / originalSize.width, bodyDimension / originalSize.height)
        let drawnSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
        let drawRect = NSRect(
            x: bodyRect.midX - drawnSize.width / 2,
            y: bodyRect.midY - drawnSize.height / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )

        let result = NSImage(size: NSSize(width: canvasDimension, height: canvasDimension))
        result.lockFocus()
        NSGraphicsContext.current?.saveGraphicsState()
        squirclePath(in: bodyRect).addClip()
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
        result.unlockFocus()
        return result
    }

    /// macOS's icon outline: a rounded rectangle with *continuous* corners
    /// (the curvature eases into the straight edges instead of switching
    /// abruptly, which `NSBezierPath(roundedRect:)`'s plain circular arcs
    /// don't do) at the icon template's 22.5% corner radius. SwiftUI's
    /// `.continuous` rounded rectangle is exactly that shape. (A superellipse
    /// was tried first and came out visibly too bulgy along the sides.)
    private static func squirclePath(in rect: NSRect) -> NSBezierPath {
        let shape = RoundedRectangle(cornerRadius: rect.width * 0.225, style: .continuous)
        return NSBezierPath(cgPath: shape.path(in: rect).cgPath)
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
        cache[bundleIdentifier] = shapedLikeSystemIcon(image)
    }

    static func removeCustomIcon(for bundleIdentifier: String) {
        try? FileManager.default.removeItem(at: fileURL(for: bundleIdentifier))
        cache[bundleIdentifier] = nil
    }
}
