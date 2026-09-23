import AppKit
import SwiftUI

/// Breeze SVG icons carry a `.ColorScheme-Text { color: #RRGGBB; }` rule
/// that Qt normally rewrites at paint time to match the active Plasma color
/// scheme, instead of shipping separate light/dark icon files. We reproduce
/// that same substitution so icons stay legible against whatever
/// `tokens.json` background they end up on.
enum ThemeIconLoader {
    private static let cache = NSCache<NSString, NSImage>()
    private static let colorSchemeRule = try? NSRegularExpression(
        pattern: "(\\.ColorScheme-Text\\s*\\{[^}]*color:\\s*)#[0-9A-Fa-f]{6}"
    )

    static func image(at url: URL, tinted hex: String) -> NSImage? {
        // Pre-colored raster brand glyphs (e.g. the Apple/Windows icons,
        // supplied as fixed-color PNG/WebP rather than a recolorable SVG):
        // load as-is, no text-based recoloring to apply.
        guard url.pathExtension.lowercased() == "svg" else {
            let cacheKey = url.path as NSString
            if let cached = cache.object(forKey: cacheKey) { return cached }
            guard let loaded = NSImage(contentsOf: url), loaded.size.width > 0, loaded.size.height > 0 else { return nil }
            // NSImage(contentsOf:) can hand back a lazily-faulting bitmap rep
            // that never actually resolves inside SwiftUI's render pass
            // (shows as nothing, not an error) — redrawing it into a fresh
            // bitmap forces the decode to happen right here, eagerly.
            let flattened = NSImage(size: loaded.size)
            flattened.lockFocus()
            loaded.draw(in: NSRect(origin: .zero, size: loaded.size))
            flattened.unlockFocus()
            cache.setObject(flattened, forKey: cacheKey)
            return flattened
        }

        let cacheKey = "\(url.path)#\(hex)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let recolored = recolor(original, to: hex)
        guard let data = recolored.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func recolor(_ svg: String, to hex: String) -> String {
        guard let colorSchemeRule else { return svg }
        let range = NSRange(svg.startIndex..., in: svg)
        return colorSchemeRule.stringByReplacingMatches(in: svg, range: range, withTemplate: "$1\(hex)")
    }
}

/// Renders a theme-provided SVG icon (see `Theme.iconURL`/`categoryIconURL`)
/// recolored to `colorHex`. Falls back to an empty space if the theme
/// doesn't ship that icon, so a missing asset never breaks layout.
struct ThemeIcon: View {
    let url: URL?
    let colorHex: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let url, let nsImage = ThemeIconLoader.image(at: url, tinted: colorHex) {
                Image(nsImage: nsImage)
                    .resizable()
                    // Some theme icons (e.g. the Apple/Windows brand glyphs)
                    // aren't square in their native viewBox — without this
                    // they'd stretch to fill a square frame instead of
                    // staying proportional.
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}
