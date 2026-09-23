import Foundation

/// Every user-facing string in the app goes through this instead of a
/// literal — backed by standard `.strings` tables (`fr`/`en`/`es`/`ru`
/// under `Resources/*.lproj`), with an optional in-app override (the
/// personalization menu's "Langue" submenu) that ignores the system's own
/// language setting. Plain `NSLocalizedString` alone always follows
/// `Bundle.main`'s automatic locale resolution, which isn't overridable
/// per-app without also controlling which bundle it reads from — hence
/// resolving our own bundle here instead of just calling through directly.
enum Localization {
    static let supportedLanguages: [(code: String, label: String)] = [
        ("fr", "Français"),
        ("en", "English"),
        ("es", "Español"),
        ("ru", "Русский")
    ]

    private static let overrideKey = "TB.language.override"

    /// `nil` means "follow the system language" (with `fr` as the
    /// ultimate fallback if the system language isn't one of the four
    /// shipped translations — see `resolvedBundle`).
    static var languageOverride: String? {
        get { UserDefaults.standard.string(forKey: overrideKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: overrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            }
            cachedBundle = nil
        }
    }

    private static var cachedBundle: Bundle?

    static func string(_ key: String) -> String {
        resolvedBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// `string(_:)` with `{n}`-style placeholders substituted — used
    /// instead of `String(format:)` since these tables don't use `%@`/`%d`
    /// positional specifiers (translators reordering words around a
    /// placeholder is exactly the kind of thing `%1$@`-style specifiers
    /// are fragile for by hand; named placeholders read unambiguously in
    /// every language's .strings file).
    static func string(_ key: String, _ replacements: [String: String]) -> String {
        var result = string(key)
        for (placeholder, value) in replacements {
            result = result.replacingOccurrences(of: "{\(placeholder)}", with: value)
        }
        return result
    }

    private static var resolvedBundle: Bundle {
        if let cachedBundle { return cachedBundle }
        let base = resourceBundle
        let code = languageOverride ?? preferredSupportedLanguageCode()
        let resolved: Bundle
        if let path = base.path(forResource: code, ofType: "lproj"), let override = Bundle(path: path) {
            resolved = override
        } else {
            resolved = base
        }
        cachedBundle = resolved
        return resolved
    }

    /// The first of the user's preferred system languages that we actually
    /// ship a translation for, else `fr` (the language the rest of this
    /// app's UI copy — alerts, menu labels — was originally written in).
    private static func preferredSupportedLanguageCode() -> String {
        let supported = Set(supportedLanguages.map(\.code))
        for preference in Locale.preferredLanguages {
            let code = String(preference.prefix(2))
            if supported.contains(code) { return code }
        }
        return "fr"
    }

    /// Mirrors `ThemeLoader.bundledThemesDirectory`: prefer the packaged
    /// .app's own `Contents/Resources` (real runtime), fall back to the
    /// SwiftPM resource bundle so `swift run` still finds translations
    /// during development.
    private static var resourceBundle: Bundle {
        if let mainResources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: mainResources.appendingPathComponent("fr.lproj").path) {
            return Bundle.main
        }
        return Bundle.module
    }
}

extension Localization {
    /// `AppDiscovery.humanCategory`'s stable, dash-cased internal keys
    /// (`"developer-tools"`, `"healthcare-fitness"`, …) to a
    /// `Localizable.strings` key — two of them (`business`, `medical`)
    /// intentionally collapse onto a sibling category's label, same as
    /// before this was split into stable-key-vs-display-label.
    static func categoryDisplayName(for key: String?) -> String {
        guard let key else { return L("category.all") }
        let aliases = ["business": "productivity", "medical": "healthcare-fitness"]
        let resolved = aliases[key] ?? key
        return L("category.\(resolved.replacingOccurrences(of: "-", with: "_"))")
    }
}

/// Shorthand for `Localization.string(_:)` — used throughout instead of
/// spelling out the enum at every call site.
func L(_ key: String) -> String { Localization.string(key) }
func L(_ key: String, _ replacements: [String: String]) -> String { Localization.string(key, replacements) }
