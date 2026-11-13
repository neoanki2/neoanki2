import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private func learningFixture() async throws -> (ItemStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("learning-time-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: folder.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    return (store, folder)
}
private func learningItem(_ deck: UUID? = nil) -> Item {
    Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
        FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
    ], deckID: deck)
}
private let learningNow = Date(timeIntervalSince1970: 1_800_000_000)
private func learningSegment(_ item: UUID, duration: Int64 = 10_000, start: Date = learningNow.addingTimeInterval(-60),
                             id: UUID = UUID(), source: UUID = UUID()) -> LearningTimeSegment {
    LearningTimeSegment(id: id, sessionID: UUID(), deviceID: UUID(), sourceLibraryID: source,
        itemID: item, cardID: UUID(), startedAt: start, endedAt: start.addingTimeInterval(Double(duration) / 1000),
        durationMilliseconds: duration)
}

@Test func learningTimeUsesCurrentHierarchyWithoutDoubleCounting() async throws {
    let (store, folder) = try await learningFixture(); defer { try? FileManager.default.removeItem(at: folder) }
    let parent = try await store.createDeck(Deck(name: "Spanish"))
    let child = try await store.createDeck(Deck(name: "Vocabulary", parentID: parent.id))
    let other = try await store.createDeck(Deck(name: "Other"))
    let direct = learningItem(parent.id), nested = learningItem(child.id)
    _ = try await store.createItem(direct); _ = try await store.createItem(nested)
    try await store.recordLearningTime([learningSegment(direct.id, duration: 600_000), learningSegment(nested.id, duration: 1_200_000)])
    // Choose an asOf after the complete intervals, not merely their start.
    let now = learningNow.addingTimeInterval(2000)
    var summary = try await store.learningTimeSummary(scope: .deck(parent.id), period: .allTime, asOf: now)
    #expect(summary.directMilliseconds == 600_000)
    #expect(summary.descendantMilliseconds == 1_200_000)
    #expect(summary.totalMilliseconds == 1_800_000)
    #expect(try await store.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: now).totalMilliseconds == 1_800_000)
    #expect(try await store.moveDeck(id: child.id, to: .inside(other.id)))
    summary = try await store.learningTimeSummary(scope: .deck(parent.id), period: .allTime, asOf: now)
    #expect(summary.totalMilliseconds == 600_000)
    #expect(try await store.learningTimeSummary(scope: .deck(other.id), period: .allTime, asOf: now).totalMilliseconds == 1_200_000)
    #expect(try await store.updateItemDeck(itemID: nested.id, deckID: parent.id))
    #expect(try await store.learningTimeSummary(scope: .deck(parent.id, includeDescendants: false), period: .allTime, asOf: now).totalMilliseconds == 1_800_000)
    #expect(try await store.updateItemDeck(itemID: nested.id, deckID: nil))
    #expect(try await store.learningTimeSummary(scope: .unassigned, period: .allTime, asOf: now).totalMilliseconds == 1_200_000)
}

@Test func learningTimeSurvivesDeletionUndoResetAndReopen() async throws {
    let (store, folder) = try await learningFixture(); defer { try? FileManager.default.removeItem(at: folder) }
    let deck = try await store.createDeck(Deck(name: "Deck")); let item = learningItem(deck.id)
    _ = try await store.createItem(item)
    let card = try #require(try await store.fetchDueCards().first)
    try await store.recordLearningTime([learningSegment(item.id)])
    let review = try await store.submitReviewWithReceipt(cardID: card.id, rating: .good, now: learningNow)
    try await store.revertReview(reviewLogID: review.reviewLogID, now: learningNow)
    _ = try await store.resetDeckProgress(id: deck.id, now: learningNow)
    #expect(try await store.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: learningNow).totalMilliseconds == 10_000)
    #expect(try await store.deleteItem(id: item.id))
    let reopened = try ItemStore(databaseURL: folder.appendingPathComponent("library.sqlite")); try await reopened.bootstrap()
    let summary = try await reopened.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: learningNow)
    #expect(summary.deletedMilliseconds == 10_000)
    #expect(summary.totalMilliseconds == 10_000)
    #expect(summary.decks.first?.totalMilliseconds == 0)
}

@Test func learningTimeRejectsConflictingIDsAtomically() async throws {
    let (store, folder) = try await learningFixture(); defer { try? FileManager.default.removeItem(at: folder) }
    let item = learningItem(); _ = try await store.createItem(item)
    let first = learningSegment(item.id)
    try await store.recordLearningTime([first, first])
    #expect(try await store.learningTimeSegments(after: 0).count == 1)
    let conflict = learningSegment(item.id, duration: 11_000, id: first.id)
    await #expect(throws: DatabaseError.idempotencyConflict) {
        try await store.recordLearningTime([learningSegment(item.id), conflict])
    }
    #expect(try await store.learningTimeSegments(after: 0).count == 1)
}

@Test func learningTimeMissingDependenciesWaitAndAliasesResolve() async throws {
    let (store, folder) = try await learningFixture(); defer { try? FileManager.default.removeItem(at: folder) }
    let original = UUID(), source = UUID()
    try await store.recordLearningTime([learningSegment(original, source: source)])
    var summary = try await store.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: learningNow)
    #expect(summary.totalMilliseconds == 0); #expect(summary.deletedMilliseconds == 0)
    #expect(summary.pendingMilliseconds == 10_000)
    let item = learningItem(); _ = try await store.createItem(item)
    try await store.recordLearningTimeAliases([.init(sourceLibraryID: source, originalItemID: original, resolvedItemID: item.id)])
    summary = try await store.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: learningNow)
    #expect(summary.totalMilliseconds == 10_000); #expect(summary.unassignedMilliseconds == 10_000)
    #expect(summary.pendingMilliseconds == 0)
}

@Test func learningTimeClipsAtStudyDayBoundaryAndDoesNotBackfillReviews() async throws {
    let (store, folder) = try await learningFixture(); defer { try? FileManager.default.removeItem(at: folder) }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 5))!
    let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 3, minute: 59, second: 30))!
    let item = learningItem(); _ = try await store.createItem(item)
    let card = try #require(try await store.fetchDueCards().first)
    _ = try await store.submitReviewWithReceipt(cardID: card.id, rating: .good, durationMs: 60_000)
    #expect(try await store.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: now).trackingStartedAt == nil)
    try await store.recordLearningTime([learningSegment(item.id, duration: 60_000, start: start)])
    #expect(try await store.learningTimeSummary(scope: .allDecks, period: .today, asOf: now, calendar: calendar).totalMilliseconds == 30_000)
    #expect(try await store.learningTimeSummary(scope: .allDecks, period: .last7Days, asOf: now, calendar: calendar).totalMilliseconds == 60_000)
    #expect(try await store.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: now).totalMilliseconds == 60_000)
}

@Test func learningTimeRangesRespectDSTAndViewingTimeZone() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 5))!
    let range = LearningTimePeriod.last7Days.range(asOf: now, rolloverMinutes: 240, calendar: calendar)
    #expect(calendar.component(.hour, from: range.start) == 4)
    #expect(calendar.component(.day, from: range.start) == 2)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let today = LearningTimePeriod.today.range(asOf: now, rolloverMinutes: 240, calendar: calendar)
    #expect(calendar.component(.hour, from: today.start) == 4)
    #expect(today.start != range.start)
}

@Test func learningTimeMigrationFromVersion31IsAdditive() async throws {
    let (store, folder) = try await learningFixture(); defer { try? FileManager.default.removeItem(at: folder) }
    let item = learningItem(); _ = try await store.createItem(item)
    var db: OpaquePointer?
    #expect(sqlite3_open(folder.appendingPathComponent("library.sqlite").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "DROP TABLE learning_time_segments; DROP TABLE learning_time_item_aliases; UPDATE schema_version SET version = 31;", nil, nil, nil) == SQLITE_OK)
    let upgraded = try ItemStore(databaseURL: folder.appendingPathComponent("library.sqlite")); try await upgraded.bootstrap()
    #expect(try await upgraded.fetchItem(id: item.id) != nil)
    try await upgraded.recordLearningTime([learningSegment(item.id)])
    #expect(try await upgraded.learningTimeSummary(scope: .allDecks, period: .allTime, asOf: learningNow).totalMilliseconds == 10_000)
}
