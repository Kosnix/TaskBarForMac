import Foundation
import SwiftUI

/// `theme.json` — identifying metadata for a theme folder.
struct ThemeManifest: Codable, Equatable {
    var id: String
    var name: String
    var author: String
    var desktopEnvironment: String
    var variant: String
    var version: String
}

struct PanelTokens: Codable, Equatable {
    var height: Double
    var backgroundColor: String
    var backgroundOpacity: Double
    var borderColor: String
    var borderWidth: Double
    var cornerRadius: Double
    var blurEnabled: Bool
}

struct ColorTokens: Codable, Equatable {
    var textPrimary: String
    var textSecondary: String
    var accent: String
    var accentText: String
    var buttonBackground: String
    var buttonBackgroundHover: String
    var buttonBackgroundActive: String
    var separator: String
}

struct TypographyTokens: Codable, Equatable {
    var fontName: String
    var fontSize: Double
}

struct SpacingTokens: Codable, Equatable {
    var itemSpacing: Double
    var edgePadding: Double
    var iconSize: Double
}

struct TaskButtonTokens: Codable, Equatable {
    var cornerRadius: Double
    var minWidth: Double
    var maxWidth: Double
    var indicatorStyle: String
    /// "iconAndLabel" or "iconOnly" — the theme's default; overridable at
    /// runtime from the right-click menu (see `ThemeStore`).
    var displayStyle: String
}

struct StartButtonTokens: Codable, Equatable {
    var showLabel: Bool
    var label: String
    /// When true, the start button's icon fills the panel's entire height
    /// edge-to-edge instead of the usual 16pt inset — the Windows 7 "Start
    /// orb" is drawn corner-to-corner in the real taskbar, unlike every
    /// other theme's smaller, inset glyph. Optional (defaults to `false`
    /// when a theme's `tokens.json` doesn't declare it) so every existing
    /// theme file keeps working unmodified.
    var fillHeight: Bool?
}

/// `tokens.json` — the design tokens every generic UI component reads from.
struct ThemeTokens: Codable, Equatable {
    var panel: PanelTokens
    var colors: ColorTokens
    var typography: TypographyTokens
    var spacing: SpacingTokens
    var taskButton: TaskButtonTokens
    var startButton: StartButtonTokens

    /// A user preference (see `ThemeStore.taskbarIconRatio`), baked into a
    /// mutable copy of the active theme's tokens at the same point
    /// `panel.height` and `taskButton.displayStyle` overrides already are
    /// (see `TaskbarView.content(for:)` and `StartMenuPanel`) — not part of
    /// any theme's own `tokens.json`, so it stays `nil` (and falls back to
    /// `defaultTaskbarIconRatio`) for every existing theme file until that
    /// override is applied.
    var taskbarIconRatio: Double?

    /// A fixed proportion of the panel's own height, rather than a flat
    /// inset (`height - 16px`) — a flat inset shrinks an icon's *share* of
    /// the bar as the bar gets taller (and grows it as the bar gets
    /// shorter), so two themes with different `panel.height` never looked
    /// consistently "sized" relative to their own bar. A fixed ratio keeps
    /// that relationship constant across every theme. Single source of
    /// truth for every task/launcher button's icon size — see
    /// `TaskButtonView`, `GroupedTaskButtonView`, `LauncherButtonView`,
    /// `TaskbarView`'s own width math, and `StartMenuView`'s session footer.
    static let defaultTaskbarIconRatio: Double = 0.7

    var taskbarIconSize: CGFloat {
        max(12, CGFloat(panel.height) * (taskbarIconRatio ?? Self.defaultTaskbarIconRatio))
    }

    /// Same override mechanism as `taskbarIconRatio` (see
    /// `ThemeStore.taskbarIconSpacingRatio`) — how much room sits between
    /// consecutive task/launcher buttons specifically, scoped to just that
    /// row rather than reusing `spacing.itemSpacing`, which also spaces out
    /// unrelated modules (the clock, the start button, …) that this
    /// setting isn't meant to touch. Expressed as a fraction of the icon's
    /// own size (like `taskbarIconRatio` is a fraction of the panel's own
    /// height) rather than a flat point value, so the gap keeps looking
    /// proportional as icons themselves are resized instead of turning
    /// cramped or oversized at the extremes.
    var taskbarIconSpacingRatio: Double?
    static let defaultTaskbarIconSpacingRatio: Double = 0.15

    /// Below 0%, there's no gap left to remove (already at zero) — the
    /// slider instead keeps tightening the row by shrinking each button's
    /// own internal padding around its icon, down to none at -100%. Above
    /// 0%, that padding is untouched (only the gap between buttons grows).
    var effectiveTaskbarIconSpacing: CGFloat {
        max(0, taskbarIconSize * (taskbarIconSpacingRatio ?? Self.defaultTaskbarIconSpacingRatio))
    }

    var effectiveTaskbarEdgePadding: CGFloat {
        let ratio = taskbarIconSpacingRatio ?? Self.defaultTaskbarIconSpacingRatio
        guard ratio < 0 else { return CGFloat(spacing.edgePadding) }
        return max(0, CGFloat(spacing.edgePadding) * CGFloat(1 + ratio))
    }
}

/// `layout.json` — which modules appear in which zone of the panel.
struct ThemeLayout: Codable, Equatable {
    var zones: Zones

    struct Zones: Codable, Equatable {
        var left: [String]
        var center: [String]
        var right: [String]
    }
}

/// A fully loaded theme: manifest + tokens + layout, plus the folder it came from
/// (so assets like icon overrides can be resolved relative to it).
struct Theme: Identifiable, Equatable {
    var manifest: ThemeManifest
    var tokens: ThemeTokens
    var layout: ThemeLayout
    /// Optional `categories.json`: maps an `AppDiscovery` category label (or
    /// the special key `"__all__"`) to one of this theme's
    /// `icons/categories/<key>.svg` files. Themes that don't ship one just
    /// fall back to a generic icon.
    var categoryIcons: [String: String]
    var folderURL: URL

    var id: String { manifest.id }

    /// A fixed, theme-provided icon such as `icons/start-button.svg`.
    /// Looks for `icons/<name>.svg` first (our recolorable convention), then
    /// falls back to a pre-colored raster asset (`.png`/`.webp`) — used for
    /// brand glyphs supplied as fixed-color images rather than a
    /// ColorScheme-Text SVG.
    func iconURL(_ name: String) -> URL? {
        for ext in ["svg", "png", "webp"] {
            let url = folderURL.appendingPathComponent("icons/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// The category icon for an `AppDiscovery` category label, or the "all
    /// applications" icon when `label` is nil.
    func categoryIconURL(forCategoryLabel label: String?) -> URL? {
        let key = label.flatMap { categoryIcons[$0] } ?? categoryIcons["__all__"] ?? "other"
        let url = folderURL.appendingPathComponent("icons/categories/\(key).svg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

extension Color {
    /// Parses "#RRGGBB" or "#RRGGBBAA" hex strings used in theme token files.
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")

        var rgba: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgba)

        let r, g, b, a: Double
        switch hexString.count {
        case 6:
            r = Double((rgba & 0xFF0000) >> 16) / 255
            g = Double((rgba & 0x00FF00) >> 8) / 255
            b = Double(rgba & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((rgba & 0xFF00_0000) >> 24) / 255
            g = Double((rgba & 0x00FF_0000) >> 16) / 255
            b = Double((rgba & 0x0000_FF00) >> 8) / 255
            a = Double(rgba & 0x0000_00FF) / 255
        default:
            r = 1; g = 0; b = 1; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
