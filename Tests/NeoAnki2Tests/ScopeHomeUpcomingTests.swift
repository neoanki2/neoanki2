import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

private func homeCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

@Test func homeUpcomingShowsAnIntradayLearningReviewBeforeItIsDue() async throws {
    let calendar = homeCalendar()
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12)))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("home-intraday-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    _ = try await store.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ]))
    let card = try #require(try await store.fetchDueCards().first)
    let memory = try await store.submitReview(cardID: card.id, rating: .again, now: now)
    #expect(memory.due > now)
    #expect(memory.due < StudyDay.nextRollover(after: now, rolloverMinutes: 240, calendar: calendar))
    let source = try await store.statisticsSource()
    let snapshot = StatisticsEngine.snapshot(source: source, query: .init(), now: now, calendar: calendar)
    let days = ScopeHomeUpcoming.days(
        points: snapshot.due, asOf: now, rollover: source.rollover, calendar: calendar)

    #expect(days.first?.isToday == true)
    #expect(days.map(\.count) == [1, 0, 0, 0, 0, 0, 0])
}

@Test func homeUpcomingIncludesTodayAndKeepsEmptyDaysButExcludesDistantCards() throws {
    let calendar = homeCalendar()
    let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 4)))
    func date(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    let days = ScopeHomeUpcoming.days(
        points: [
            .init(date: today, series: "Scheduled cards", value: 121),
            .init(date: date(1), series: "Scheduled cards", value: 42),
            .init(date: date(3), series: "Scheduled cards", value: 61),
            .init(date: date(6), series: "Scheduled cards", value: 16),
            .init(date: date(7), series: "Scheduled cards", value: 99),
        ], asOf: today.addingTimeInterval(3600), rollover: 240, calendar: calendar)

    #expect(days.map(\.date) == (0..<7).map(date))
    #expect(days.map(\.count) == [121, 42, 0, 61, 0, 0, 16])
    #expect(days.map(\.isToday) == [true, false, false, false, false, false, false])
}

@Test(arguments: [3, 10], [240, 150])
func homeUpcomingUsesStudyRolloverAcrossDaylightSavingChanges(month: Int, rollover: Int) throws {
    let calendar = homeCalendar()
    // At 02:00 before rollover, Today is still the previous calendar day's
    // study bucket. Keep boundaries correct across 23- and 25-hour dates.
    let date = try #require(calendar.date(from: DateComponents(
        year: 2026, month: month, day: month == 3 ? 7 : 31, hour: 2)))
    let first = StudyDay.start(for: date, rolloverMinutes: rollover, calendar: calendar)
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
