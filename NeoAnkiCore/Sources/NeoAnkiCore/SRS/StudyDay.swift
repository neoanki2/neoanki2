import Foundation

/// Defines the learner's local study day independently of calendar midnight.
public enum StudyDay {
    public static let defaultRolloverMinutes = 4 * 60
    public static let validRolloverMinutes = 0 ..< 24 * 60

    public static func key(
        for date: Date,
        rolloverMinutes: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let rollover = normalized(rolloverMinutes)
        let startOfCalendarDay = calendar.startOfDay(for: date)
        let rolloverToday = calendar.date(
            bySettingHour: rollover / 60,
            minute: rollover % 60,
            second: 0,
            of: startOfCalendarDay
        ) ?? startOfCalendarDay
        let studyDayStart = date < rolloverToday
            ? calendar.date(byAdding: .day, value: -1, to: startOfCalendarDay) ?? startOfCalendarDay
            : startOfCalendarDay
        let components = calendar.dateComponents([.year, .month, .day], from: studyDayStart)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    public static func nextRollover(
        after date: Date,
        rolloverMinutes: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let rollover = normalized(rolloverMinutes)
        let hour = rollover / 60
        let minute = rollover % 60
        let candidate = calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
        return candidate ?? calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }

    private static func normalized(_ minutes: Int) -> Int {
        min(max(minutes, validRolloverMinutes.lowerBound), validRolloverMinutes.upperBound - 1)
    }
}
