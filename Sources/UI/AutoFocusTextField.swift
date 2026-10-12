import AppKit
import SwiftUI

enum TextFieldNavigation {
    case up, down, left, right
}

/// The shared look for every start menu's search field: a neutral filled
/// pill (for contrast against the panel — without it, Kickoff's and
/// Windows 7's fields had no visible box at all, just text floating over
/// the translucent background) with a thin border in the theme's own
/// accent color (rather than a solid accent fill, which read as a heavy,
/// overly saturated block instead of a subtle "this theme's" highlight).
struct SearchFieldBackground: View {
    let tokens: ThemeTokens
    var liquidGlassEnabled: Bool = false
    var liquidGlassIntensity: Double = 0.35
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if liquidGlassEnabled {
                // Same glass material/formula as `PanelBackground` and
                // `GlassButtonBackground` — a flat, fully opaque fill here
                // (however light) read as a mismatched sticker pasted on
                // top of the panel's own translucent blur instead of part
                // of the same glass surface.
                ZStack {
                    VisualEffectView(material: .sidebar, blendingMode: .behindWindow, appearance: tokens.materialAppearance)
                    Color(hex: tokens.colors.buttonBackgroundHover).opacity(liquidGlassIntensity * 0.85)
                }
            } else {
                // `buttonBackgroundHover`, not the plain `buttonBackground`
                // — every theme already defines it as a visibly lighter
                // step up from the base control color, the same "stands
                // out a bit more" role a search field needs.
                Color(hex: tokens.colors.buttonBackgroundHover)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(hex: tokens.colors.accent).opacity(0.6), lineWidth: 1.5)
        )
    }
}

/// A plain `NSTextField` wrapper that grabs keyboard focus as soon as it's
/// added to the window — so typing works immediately when the start menu
/// opens, no click required — and forwards arrow keys / Return instead of
/// letting the text field consume them, so the app grid can be navigated
/// and launched without leaving the search field. Deliberately not SwiftUI's
/// own `TextField` + `@FocusState`: `@FocusState` needs the same Xcode-only
/// compiler-macro plugin `@State` does (see `ShortcutsManager`), which this
/// project avoids so it stays buildable with plain `swift build`.
struct AutoFocusNSTextField: NSViewRepresentable {
    var text: Binding<String>
    var textColor: NSColor = .labelColor
    /// The blinking cursor and text-selection highlight otherwise default to
    /// the *system* accent color (System Settings' own pick), completely
    /// unrelated to whichever theme is active — this makes them follow the
    /// theme's own accent instead, like every other accented element in the
    /// start menu.
    var accentColor: NSColor = .controlAccentColor
    var fontSize: CGFloat = 13
    var onNavigate: ((TextFieldNavigation) -> Void)?
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.appearance = Self.appearance(matching: textColor)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = textColor
        field.stringValue = text.wrappedValue
        field.delegate = context.coordinator
        // Never actually forced to a single line before — a plain
        // `NSTextField`'s cell wraps by default, so a placeholder or typed
        // string too wide for the field's own width (the search field's
        // fixed height, set by its SwiftUI `.frame`, never grew to match)
        // wrapped onto a second line and spilled past the pill background
        // behind it instead of just getting clipped/truncated.
        // `isScrollable` deliberately left alone — it fights with
        // `.byTruncatingTail` (a truncated cell isn't meant to be
        // scrollable too) and set together the field rendered as
        // completely empty instead of either behavior.
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.usesSingleLineMode = true

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            context.coordinator.applyAccentColor(to: field)
        }
        return field
    }

    /// Pins the field to a light or dark appearance chosen from the *text
    /// color* it's been given, instead of following the system's. AppKit
    /// still resolves some of a field's own colors (the empty-state
    /// placeholder above all) against its effective appearance regardless
    /// of the explicit colors set on it, so with a dark theme under a
    /// light-mode macOS the placeholder came out dark grey on the dark
    /// translucent search pill — unreadable. Light text means a dark
    /// theme and vice versa, the same rule `ThemeTokens.materialAppearance`
    /// applies to the glass behind it.
    private static func appearance(matching textColor: NSColor) -> NSAppearance? {
        guard let rgb = textColor.usingColorSpace(.sRGB) else { return nil }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return NSAppearance(named: luminance > 0.5 ? .darkAqua : .aqua)
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.appearance = Self.appearance(matching: textColor)
        if nsView.stringValue != text.wrappedValue {
            nsView.stringValue = text.wrappedValue
        }
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onSubmit = onSubmit
        context.coordinator.accentColor = accentColor
        context.coordinator.textColor = textColor
        nsView.textColor = textColor
        context.coordinator.applyAccentColor(to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, accentColor: accentColor, textColor: textColor, onNavigate: onNavigate, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        var accentColor: NSColor
        var textColor: NSColor
        var onNavigate: ((TextFieldNavigation) -> Void)?
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, accentColor: NSColor, textColor: NSColor, onNavigate: ((TextFieldNavigation) -> Void)?, onSubmit: (() -> Void)?) {
            self.text = text
            self.accentColor = accentColor
            self.textColor = textColor
            self.onNavigate = onNavigate
            self.onSubmit = onSubmit
        }

        /// The cursor/selection color lives on the field editor (a shared
        /// `NSTextView`), which only exists once the field is actually first
        /// responder — so this is re-applied on every editing session
        /// (`controlTextDidBeginEditing`) as well as right after focus is
        /// first grabbed, not just once at creation.
        func applyAccentColor(to field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            // The field editor (the view that actually shows what's typed)
            // doesn't always inherit the field's own `textColor`, which left
            // typed text a different color from the placeholder.
            editor.textColor = textColor
            editor.typingAttributes[.foregroundColor] = textColor
            editor.insertionPointColor = accentColor
            editor.selectedTextAttributes = [.backgroundColor: accentColor.withAlphaComponent(0.3)]
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            applyAccentColor(to: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                onNavigate?(.down)
                return true
            case #selector(NSResponder.moveUp(_:)):
                onNavigate?(.up)
                return true
            case #selector(NSResponder.moveLeft(_:)):
                onNavigate?(.left)
                return true
            case #selector(NSResponder.moveRight(_:)):
                onNavigate?(.right)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit?()
                return true
            default:
                return false
            }
        }
    }
}

/// What every start menu actually uses. The placeholder is drawn here, in
/// SwiftUI, rather than by the `NSTextField` itself: AppKit's own
/// placeholder rendering resolved to a dark grey on the dark glass pill on
/// real screens (reported on the Windows 11 and Kickoff menus) even though
/// explicit colors were set on it, and a plain SwiftUI `Text` takes exactly
/// the color it's given.
struct AutoFocusTextField: View {
    var placeholder: String
    var text: Binding<String>
    var textColor: NSColor = .labelColor
    var accentColor: NSColor = .controlAccentColor
    var fontSize: CGFloat = 13
    var onNavigate: ((TextFieldNavigation) -> Void)?
    var onSubmit: (() -> Void)?

    var body: some View {
        ZStack(alignment: .leading) {
            AutoFocusNSTextField(
                text: text,
                textColor: textColor,
                accentColor: accentColor,
                fontSize: fontSize,
                onNavigate: onNavigate,
                onSubmit: onSubmit
            )
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color(nsColor: textColor))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    // The field's own text starts a few points in from its
                    // edge; lines the placeholder up with it.
                    .padding(.leading, 2)
            }
        }
    }
}
