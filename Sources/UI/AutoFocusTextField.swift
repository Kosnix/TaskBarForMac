import AppKit
import SwiftUI

enum TextFieldNavigation {
    case up, down, left, right
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
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text.wrappedValue {
            nsView.stringValue = text.wrappedValue
        }
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onNavigate: onNavigate, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        var onNavigate: ((TextFieldNavigation) -> Void)?
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, onNavigate: ((TextFieldNavigation) -> Void)?, onSubmit: (() -> Void)?) {
            self.text = text
            self.onNavigate = onNavigate
            self.onSubmit = onSubmit
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
