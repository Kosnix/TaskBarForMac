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
    /// The start menu style that goes with the theme (`StartMenuStyle` raw
    /// value) — applied when "adapt the start menu to the theme" is on.
    var startMenuStyle: String?
}

/// A top-to-bottom colour ramp. `locations` (0…1, one per colour) place the
/// stops; without them they're spread evenly.
struct GradientTokens: Codable, Equatable {
    var colors: [String]
    var locations: [Double]?

    var gradient: Gradient {
        let stops = colors.enumerated().map { index, hex -> Gradient.Stop in
            let location = locations.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                ?? (colors.count > 1 ? Double(index) / Double(colors.count - 1) : 0)
            return Gradient.Stop(color: Color(hex: hex), location: location)
        }
        return Gradient(stops: stops)
    }

    var linear: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
    }
}

struct PanelTokens: Codable, Equatable {
    var height: Double
    var backgroundColor: String
    var backgroundOpacity: Double
    var borderColor: String
    var borderWidth: Double
    var cornerRadius: Double
    var blurEnabled: Bool
    /// A gradient bar — drawn instead of the flat/glass background,
    /// whatever the glass setting says. Opaque for Windows XP's Luna; with
    /// translucent colours and `blurEnabled` it's Windows 7's Aero glass: the
    /// gradient tints the blurred desktop behind the bar.
    var gradient: GradientTokens?
    /// A 1pt line along the bar's top edge (Aero's bright rim).
    var edgeHighlight: String?
    /// A 1pt dark line right at the top, above the highlight (Aero's outer
    /// edge).
    var edgeDark: String?
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

/// Raised, bevelled task buttons (Windows XP): a filled button for every
    /// window, pressed-in while it's the active one — instead of the plain
    /// icon with an underline.
struct RaisedButtonTokens: Codable, Equatable {
    var cornerRadius: Double
    var fill: GradientTokens
    var hoverFill: GradientTokens
    var activeFill: GradientTokens
    /// Outer edge, and the lighter 1pt line just inside it (top and left).
    var border: String
    var activeBorder: String
    var highlight: String
    var textColor: String?
}

struct TaskButtonTokens: Codable, Equatable {
    var raised: RaisedButtonTokens?
    var cornerRadius: Double
    var minWidth: Double
    var maxWidth: Double
    var indicatorStyle: String
    /// "iconAndLabel" or "iconOnly" — the theme's default; overridable at
    /// runtime from the right-click menu (see `ThemeStore`).
    var displayStyle: String
}

/// A drawn start button instead of an icon (Windows XP's green "start" tab
/// with the flag): flush with the bar's left edge, rounded on the right.
struct StartTabTokens: Codable, Equatable {
    var fill: GradientTokens
    var hoverFill: GradientTokens
    var pressedFill: GradientTokens
    var border: String
    var textColor: String
    var textShadow: String
    var cornerRadius: Double
}

struct StartButtonTokens: Codable, Equatable {
    var tab: StartTabTokens?
    var showLabel: Bool
    var label: String
    /// When true, the start button's icon fills the panel's entire height
    /// edge-to-edge instead of the usual 16pt inset — the Windows 7 "Start
    /// orb" is drawn corner-to-corner in the real taskbar, unlike every
    /// other theme's smaller, inset glyph. Optional (defaults to `false`
    /// when a theme's `tokens.json` doesn't declare it) so every existing
    /// theme file keeps working unmodified.
    var fillHeight: Bool?
    /// With `fillHeight`, the icon's size as a fraction of the bar's height
    /// (the Windows 7 orb is a little smaller than the bar it sits in).
    var fillScale: Double?
}

struct TrayTokens: Codable, Equatable {
    var fill: GradientTokens
    var border: String
    var highlight: String
}

/// The proportions a theme is meant to be seen with (the real thing's bar
/// height, icon size and button spacing). Applied when the theme is picked
/// in Settings and "adjust the layout to the theme" is on; the sliders still
/// adjust them afterwards. A theme without a preset brings the app's defaults
/// and its own bar height, with icon-only buttons, left-aligned.
struct ThemePreset: Codable, Equatable {
    var barHeight: Double?
    var iconRatio: Double?
    var iconSpacingRatio: Double?
    var iconHoverZoom: Double?
    /// Whether the windows' names are shown next to their icons.
    var showNames: Bool?
    /// Whether the icons are centered in the bar, and whether the start
    /// button travels to the middle with them (Windows 11).
    var centered: Bool?
    var centerIncludesStart: Bool?
}

/// `tokens.json` — the design tokens every generic UI component reads from.
struct ThemeTokens: Codable, Equatable {
    var panel: PanelTokens
    var colors: ColorTokens
    var typography: TypographyTokens
    var spacing: SpacingTokens
    var taskButton: TaskButtonTokens
    var startButton: StartButtonTokens
    /// A tinted block behind the right-hand zone (Windows XP's notification
    /// area), with a bevelled left edge.
    var tray: TrayTokens?
    var preset: ThemePreset?

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

    /// Same override mechanism as `taskbarIconRatio`/`taskbarIconSpacingRatio`
    /// — how much a taskbar icon grows on hover (`.hoverLift`), as a plain
    /// fraction (0.12 = +12%) rather than a fixed point amount, so it scales
    /// sensibly whatever size the icon itself ends up being.
    var taskbarIconHoverZoomRatio: Double?
    static let defaultTaskbarIconHoverZoomRatio: Double = 0.10

    var effectiveTaskbarIconHoverZoom: Double {
        taskbarIconHoverZoomRatio ?? Self.defaultTaskbarIconHoverZoomRatio
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

extension ThemeTokens {
    /// Which tone the translucent glass behind this theme's text has to be.
    /// A `NSVisualEffectView` material follows the *system* appearance by
    /// default, so a dark theme (light text) over a light-mode macOS got a
    /// pale blurred backdrop under white text — illegible on a white
    /// wallpaper. Judged from the theme's own text color (light text means
    /// a dark theme) rather than the system setting, since the theme is
    /// what picked the text color in the first place.
    var materialAppearance: NSAppearance? {
        var hex = colors.textPrimary.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if hex.count == 8 { hex = String(hex.prefix(6)) }
        var rgb: UInt64 = 0
        guard hex.count == 6, Scanner(string: hex).scanHexInt64(&rgb) else { return nil }
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return NSAppearance(named: luminance > 0.5 ? .darkAqua : .aqua)
    }
}

extension ThemeTokens {
    /// An Aero-style glass bar (translucent gradient, no XP-style tray
    /// block): its right-hand zone is lighter — small icons, tight spacing —
    /// and its clock is two equal white lines.
    var isGlassBar: Bool { panel.gradient != nil && tray == nil }

    /// The theme's own typeface when it names one (`typography.fontName`),
    /// else the system font. Used by the places that carry a theme's
    /// character — Windows XP's Tahoma and the italic "start".
    func font(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        var font: Font = typography.fontName == "system" ? .system(size: size) : .custom(typography.fontName, size: size)
        font = font.weight(weight)
        return italic ? font.italic() : font
    }
}

/// Blends two "#RRGGBB" colours: `t` of the way from `a` to `b` (0 is `a`,
/// 1 is `b`). How the Windows XP and 7 menus take their colours from
/// whichever theme is in use.
func mixHex(_ a: String, _ b: String, _ t: Double) -> String {
    func parse(_ hex: String) -> (Double, Double, Double) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if h.count == 8 { h = String(h.prefix(6)) }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }
    let (r1, g1, b1) = parse(a), (r2, g2, b2) = parse(b)
    func channel(_ x: Double, _ y: Double) -> Int { Int((x + (y - x) * t).rounded()) }
    return String(format: "#%02X%02X%02X", channel(r1, r2), channel(g1, g2), channel(b1, b2))
}

extension ThemeTokens {
    /// Light text means a dark theme.
    var isDarkTheme: Bool { materialAppearance?.name == .darkAqua }
}
