import Foundation

/// A small arithmetic evaluator for the start menus' search box: typing
/// "12*7" or "(3,5+1)/2" shows the answer. Hand-written instead of
/// `NSExpression`, which raises an uncatchable Objective-C exception on
/// anything it can't parse — unacceptable for text typed live.
///
/// Understands `+ - * / ^`, `x`/`×`/`÷`, unary minus, parentheses, and
/// either `.` or `,` as the decimal mark. Returns nil for anything else, and
/// for input with no operator at all (a bare number is just a search).
enum Calculator {
    static func evaluate(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
            .replacingOccurrences(of: " ", with: "")
        guard normalized.contains(where: { "+-*/^".contains($0) }),
              normalized.contains(where: \.isNumber),
              normalized.allSatisfy({ $0.isNumber || "+-*/^().".contains($0) }) else { return nil }
        var parser = Parser(characters: Array(normalized))
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
        return value
    }

    /// "84", "3,5", "0,333333333" — the locale's decimal mark, no trailing zeros.
    static func format(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumSignificantDigits = 10
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        var isAtEnd: Bool { position >= characters.count }

        private var current: Character? { position < characters.count ? characters[position] : nil }

        // expression := term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = current, op == "+" || op == "-" {
                position += 1
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := power (('*' | '/') power)*
        private mutating func parseTerm() -> Double? {
            guard var value = parsePower() else { return nil }
            while let op = current, op == "*" || op == "/" {
                position += 1
                guard let rhs = parsePower() else { return nil }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        // power := unary ('^' power)?   (right-associative)
        private mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if current == "^" {
                position += 1
                guard let exponent = parsePower() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        // unary := '-' unary | '+' unary | primary
        private mutating func parseUnary() -> Double? {
            if current == "-" { position += 1; return parseUnary().map { -$0 } }
            if current == "+" { position += 1; return parseUnary() }
            return parsePrimary()
        }

        // primary := number | '(' expression ')'
        private mutating func parsePrimary() -> Double? {
            if current == "(" {
                position += 1
                guard let value = parseExpression(), current == ")" else { return nil }
                position += 1
                return value
            }
            let start = position
            while let c = current, c.isNumber || c == "." { position += 1 }
            guard position > start else { return nil }
            return Double(String(characters[start..<position]))
        }
    }
}
