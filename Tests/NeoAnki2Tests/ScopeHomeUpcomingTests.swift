import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

private func homeCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

@Test func homeUpcomingKeepsEmptyDaysAndExcludesTodayAndDistantCards() throws {
    let calendar = homeCalendar()
    let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 4)))
    func date(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    let days = ScopeHomeUpcoming.days(
        points: [
            .init(date: today, series: "Scheduled cards", value: 121),
            .init(date: date(1), series: "Scheduled cards", value: 42),
            .init(date: date(3), series: "Scheduled cards", value: 61),
            .init(date: date(7), series: "Scheduled cards", value: 16),
            .init(date: date(8), series: "Scheduled cards", value: 99),
        ], asOf: today.addingTimeInterval(3600), rollover: 240, calendar: calendar)

    #expect(days.map(\.date) == (1...7).map(date))
    #expect(days.map(\.count) == [42, 0, 61, 0, 0, 0, 16])
}

@Test(arguments: [3, 10], [240, 150])
func homeUpcomingUsesStudyRolloverAcrossDaylightSavingChanges(month: Int, rollover: Int) throws {
    let calendar = homeCalendar()
    // At 02:00 before the 04:00 rollover, the first future bucket is today's
    // 04:00, even when the next seven dates span a 23- or 25-hour calendar day.
    let date = try #require(calendar.date(from: DateComponents(
        year: 2026, month: month, day: month == 3 ? 7 : 31, hour: 2)))
    let first = StudyDay.nextRollover(after: date, rolloverMinutes: rollover, calendar: calendar)
    let last = calendar.date(byAdding: .day, value: 6, to: first)!
    let days = ScopeHomeUpcoming.days(
        points: [.init(date: first, series: "Scheduled cards", value: 7),
                 .init(date: last, series: "Scheduled cards", value: 11)],
        asOf: date, rollover: rollover, calendar: calendar)

    #expect(days.count == 7)
    #expect(days.first?.date == first)
    #expect(days.last?.date == last)
    #expect(days.map(\.count) == [7, 0, 0, 0, 0, 0, 11])
    #expect(calendar.component(.hour, from: days[6].date) == rollover / 60)
    #expect(calendar.component(.minute, from: days[6].date) == rollover % 60)
}
