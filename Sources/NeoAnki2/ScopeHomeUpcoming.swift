import Foundation
import NeoAnkiCore

/// The home chart is current scheduling evidence, not a simulation of future
/// grades. Preserve empty study days so gaps never collapse the seven-day axis.
enum ScopeHomeUpcoming {
    struct Day: Identifiable {
        var id: Date { date }
        let date: Date
        let count: Int
    }

    static func days(
        points: [StatisticsPoint], asOf: Date, rollover: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Day] {
        let today = StudyDay.start(for: asOf, rolloverMinutes: rollover, calendar: calendar)
        let minutes = min(max(rollover, 0), 24 * 60 - 1)
        let counts = Dictionary(grouping: points, by: \.date)
            .mapValues { $0.reduce(0) { $0 + Int($1.value) } }
        return (1...7).compactMap { offset in
            // Resolve each boundary separately: a skipped 02:30 rollover must
            // not shift every following day's boundary to 03:00 after DST.
            guard let calendarDay = calendar.date(
                byAdding: .day, value: offset, to: calendar.startOfDay(for: today)),
                let date = calendar.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: calendarDay)
            else { return nil }
            return Day(date: date, count: counts[date, default: 0])
        }
    }
}
