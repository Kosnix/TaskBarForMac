import Observation
import SwiftUI

/// Which month the calendar popup is showing — an `@Observable` object
/// instead of `@State` (unavailable in this project, see `ShortcutsManager`).
@Observable
final class CalendarPopupModel {
    var monthOffset = 0
}

/// A plain month grid for the clock's popup: today highlighted in the
/// theme's accent color, previous/next month arrows, and a shortcut to
/// open the Calendar app.
struct CalendarPopupView: View {
    let tokens: ThemeTokens
    /// Time-zone identifiers, comma-separated (see `ThemeStore.extraTimeZones`).
    var extraTimeZones = ""
    let model = CalendarPopupModel()

    private var zones: [(name: String, zone: TimeZone)] {
        extraTimeZones.split(separator: ",").compactMap { raw in
            let identifier = raw.trimmingCharacters(in: .whitespaces)
            guard let zone = TimeZone(identifier: identifier) else { return nil }
            let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
            return (city, zone)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Localization.effectiveLocale
        return calendar
    }

    private var shownMonth: Date {
        calendar.date(byAdding: .month, value: model.monthOffset, to: Date()) ?? Date()
    }

    /// Weekday initials starting from the locale's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// One entry per grid cell — `nil` for the blanks before the 1st.
    private var days: [Int?] {
        let calendar = calendar
        guard let range = calendar.range(of: .day, in: .month, for: shownMonth),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: shownMonth)) else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.map { Optional($0) }
    }

    private func isToday(_ day: Int) -> Bool {
        let calendar = calendar
        let components = calendar.dateComponents([.year, .month], from: shownMonth)
        guard let date = calendar.date(from: DateComponents(year: components.year, month: components.month, day: day)) else { return false }
        return calendar.isDateInToday(date)
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(34), spacing: 2), count: 7)
        VStack(spacing: 8) {
            HStack {
                Text(shownMonth, format: .dateTime.month(.wide).year())
                    .font(.system(size: tokens.typography.fontSize + 2, weight: .semibold))
                    .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                Spacer()
                arrow("chevron.up") { model.monthOffset -= 1 }
                arrow("chevron.down") { model.monthOffset += 1 }
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: tokens.typography.fontSize - 1))
                        .foregroundStyle(Color(hex: tokens.colors.textSecondary))
                        .frame(height: 22)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let today = isToday(day)
                        Text("\(day)")
                            .font(.system(size: tokens.typography.fontSize, weight: today ? .semibold : .regular))
                            .foregroundStyle(Color(hex: today ? tokens.colors.accentText : tokens.colors.textPrimary))
                            .frame(width: 32, height: 28)
                            .background(Circle().fill(today ? Color(hex: tokens.colors.accent) : .clear))
                    } else {
                        Color.clear.frame(width: 32, height: 28)
                    }
                }
            }
            if !zones.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.name)
                                .font(.system(size: tokens.typography.fontSize))
                            Spacer()
                            TimelineView(.everyMinute) { context in
                                Text(context.date, format: Date.FormatStyle(timeZone: entry.zone).hour().minute())
                                    .font(.system(size: tokens.typography.fontSize, weight: .medium))
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                    }
                }
            }
            Button(L("calendar.open")) {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
                BarPopups.shared.close()
            }
            .buttonStyle(.plain)
            .font(.system(size: tokens.typography.fontSize))
            .foregroundStyle(Color(hex: tokens.colors.accent))
        }
        .padding(14)
        .frame(width: 7 * 34 + 6 * 2 + 28)
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: tokens.colors.textPrimary))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
