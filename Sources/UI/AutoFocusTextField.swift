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
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(hex: tokens.colors.buttonBackground))
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
struct AutoFocusTextField: NSViewRepresentable {
    var placeholder: String
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
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = textColor
        field.stringValue = text.wrappedValue
        field.delegate = context.coordinator

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            context.coordinator.applyAccentColor(to: field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text.wrappedValue {
            nsView.stringValue = text.wrappedValue
        }
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onSubmit = onSubmit
        context.coordinator.accentColor = accentColor
        context.coordinator.applyAccentColor(to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, accentColor: accentColor, onNavigate: onNavigate, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        var accentColor: NSColor
        var onNavigate: ((TextFieldNavigation) -> Void)?
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, accentColor: NSColor, onNavigate: ((TextFieldNavigation) -> Void)?, onSubmit: (() -> Void)?) {
            self.text = text
            self.accentColor = accentColor
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
