import Foundation
import Testing
@testable import NeoAnkiCore

private func dailyLimitStore() async throws -> ItemStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-daily-limit-\(UUID().uuidString)", isDirectory: true)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    return store
}

private func dailyLimitItem(_ title: String, deckID: UUID? = nil) -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text(title)),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ],
        deckID: deckID
    )
}

private let dailyLimitNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func dailyLimitCapsQueuesCountsAndSummaries() async throws {
    let store = try await dailyLimitStore()
    let deck = Deck(name: "Limited", newCardsPerDay: 2)
    _ = try await store.createDeck(deck)
    for index in 1 ... 3 {
        _ = try await store.createItem(
            dailyLimitItem("Card \(index)", deckID: deck.id),
            now: dailyLimitNow
        )
    }

    let due = try await store.fetchDueCards(
        scope: .deck(deck.id, includeDescendants: false),
        asOf: dailyLimitNow
    )
    let summary = try await store.scopeSummary(
        scope: .deck(deck.id, includeDescendants: false),
        asOf: dailyLimitNow
    )

    #expect(due.count == 2)
    #expect(try await store.dueCount(
        scope: .deck(deck.id, includeDescendants: false),
        asOf: dailyLimitNow
    ) == 2)
    #expect(summary.dueNow == 2)
    #expect(summary.newCount == 3)
    #expect(summary.availableNewCount == 2)
    #expect(summary.hiddenNewCount == 1)
    #expect(summary.nextNewCardsAt != nil)
}

@Test func gradingConsumesCapacityAndUndoRestoresIt() async throws {
    let store = try await dailyLimitStore()
    let deck = Deck(name: "One a day", newCardsPerDay: 1)
    _ = try await store.createDeck(deck)
    _ = try await store.createItem(
        dailyLimitItem("First", deckID: deck.id),
        now: dailyLimitNow
    )
    _ = try await store.createItem(
        dailyLimitItem("Second", deckID: deck.id),
        now: dailyLimitNow
    )

    let first = try #require(try await store.fetchDueCards(asOf: dailyLimitNow).first)
    let submission = try await store.submitReviewWithReceipt(
        cardID: first.card.id,
        rating: .again,
        now: dailyLimitNow
    )
    let afterGrade = try await store.fetchDueCards(asOf: dailyLimitNow)
    #expect(afterGrade.count == 1)
    #expect(afterGrade.first?.card.memory.phase == .learning)

    try await store.revertReview(reviewLogID: submission.reviewLogID, now: dailyLimitNow)
    let afterUndo = try await store.fetchDueCards(asOf: dailyLimitNow)
    #expect(afterUndo.count == 1)
    #expect(afterUndo.first?.card.memory.phase == .new)
}

@Test func parentLimitCapsItsEntireSubtree() async throws {
    let store = try await dailyLimitStore()
    let parent = Deck(name: "Parent", newCardsPerDay: 2)
    let firstChild = Deck(name: "First child", parentID: parent.id)
    let secondChild = Deck(name: "Second child", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(firstChild)
    _ = try await store.createDeck(secondChild)
    for index in 1 ... 2 {
        _ = try await store.createItem(
            dailyLimitItem("First child \(index)", deckID: firstChild.id),
            now: dailyLimitNow
        )
        _ = try await store.createItem(
            dailyLimitItem("Second child \(index)", deckID: secondChild.id),
            now: dailyLimitNow
        )
    }

    let due = try await store.fetchDueCards(
        scope: .deck(parent.id, includeDescendants: true),
        asOf: dailyLimitNow
    )
    #expect(due.count == 2)

    let childDue = try await store.fetchDueCards(
        scope: .deck(firstChild.id, includeDescendants: false),
        asOf: dailyLimitNow
    )
    #expect(childDue.count == 2)

    _ = try await store.submitReviewWithReceipt(
        cardID: try #require(childDue.first).card.id,
        rating: .again,
        now: dailyLimitNow
    )
    let afterGrade = try await store.fetchDueCards(
        scope: .deck(parent.id, includeDescendants: true),
        asOf: dailyLimitNow
    )
    #expect(afterGrade.count == 2)
    #expect(afterGrade.count { $0.card.memory.phase == .new } == 1)
    #expect(afterGrade.count { $0.card.memory.phase == .learning } == 1)
}

@Test func subdeckCanAddAStricterLimit() async throws {
    let store = try await dailyLimitStore()
    let parent = Deck(name: "Parent", newCardsPerDay: 3)
    let child = Deck(name: "Child", parentID: parent.id, newCardsPerDay: 1)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)
    for index in 1 ... 2 {
        _ = try await store.createItem(
            dailyLimitItem("Child \(index)", deckID: child.id),
            now: dailyLimitNow
        )
    }

    let due = try await store.fetchDueCards(
        scope: .deck(parent.id, includeDescendants: true),
        asOf: dailyLimitNow
    )
    #expect(due.count == 1)
}

/// A card rejected by a stricter child limit must not consume one of its
/// parent's slots. The parent should keep scanning its ordered candidates and
/// backfill the slot from another subdeck.
@Test func childLimitRejectionBackfillsTheParentAllowance() async throws {
    let store = try await dailyLimitStore()
    let parent = Deck(name: "Parent", newCardsPerDay: 2)
    let limitedChild = Deck(name: "Limited child", parentID: parent.id, newCardsPerDay: 1)
    let unlimitedChild = Deck(name: "Unlimited child", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(limitedChild)
    _ = try await store.createDeck(unlimitedChild)

    _ = try await store.createItem(
        dailyLimitItem("Limited first", deckID: limitedChild.id),
        now: dailyLimitNow
    )
    _ = try await store.createItem(
        dailyLimitItem("Limited second", deckID: limitedChild.id),
        now: dailyLimitNow.addingTimeInterval(1)
    )
    _ = try await store.createItem(
        dailyLimitItem("Parent backfill", deckID: unlimitedChild.id),
        now: dailyLimitNow.addingTimeInterval(2)
    )
    let asOf = dailyLimitNow.addingTimeInterval(3)

    let due = try await store.fetchDueCards(
        scope: .deck(parent.id, includeDescendants: true),
        asOf: asOf
    )
    let summary = try await store.scopeSummary(
        scope: .deck(parent.id, includeDescendants: true),
        asOf: asOf
    )

    #expect(due.count == 2)
    #expect(due.map(\.card.deckID) == [limitedChild.id, unlimitedChild.id])
    #expect(summary.dueNow == 2)
    #expect(summary.availableNewCount == 2)
    #expect(summary.hiddenNewCount == 1)
}

@Test func zeroLimitDoesNotRestrictUnassignedCardsOrReviews() async throws {
    let store = try await dailyLimitStore()
    let deck = Deck(name: "Paused", newCardsPerDay: 0)
    _ = try await store.createDeck(deck)
    _ = try await store.createItem(
        dailyLimitItem("Paused new", deckID: deck.id),
        now: dailyLimitNow
    )
    _ = try await store.createItem(dailyLimitItem("Unassigned"), now: dailyLimitNow)

    let due = try await store.fetchDueCards(asOf: dailyLimitNow)
    #expect(due.count == 1)
    #expect(due.first?.card.deckID == nil)
}

@Test func studyDayUsesConfiguredLocalRolloverAcrossDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let before = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 3,
        day: 8,
        hour: 3,
        minute: 59
    )))
    let after = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 3,
        day: 8,
        hour: 4,
        minute: 0
    )))

    #expect(StudyDay.key(for: before, rolloverMinutes: 240, calendar: calendar) == "2026-03-07")
    #expect(StudyDay.key(for: after, rolloverMinutes: 240, calendar: calendar) == "2026-03-08")
    #expect(
        calendar.dateComponents(
            [.hour, .minute],
            from: StudyDay.nextRollover(
                after: before,
                rolloverMinutes: 240,
                calendar: calendar
            )
        ) == DateComponents(hour: 4, minute: 0)
    )
}

@Test func rolloverPreferencePersistsAndValidates() async throws {
    let store = try await dailyLimitStore()
    #expect(try await store.studyDayRolloverMinutes() == 240)

    try await store.setStudyDayRolloverMinutes(90)
    #expect(try await store.studyDayRolloverMinutes() == 90)

    await #expect(throws: DatabaseError.self) {
        try await store.setStudyDayRolloverMinutes(1_440)
    }
}

@Test func customRolloverStartsAFreshDeckBudget() async throws {
    let store = try await dailyLimitStore()
    try await store.setStudyDayRolloverMinutes(60)
    let calendar = Calendar.autoupdatingCurrent
    let midnight = calendar.startOfDay(for: .now)
    let beforeRollover = try #require(
        calendar.date(byAdding: .minute, value: 30, to: midnight)
    )
    let afterRollover = try #require(
        calendar.date(byAdding: .minute, value: 90, to: midnight)
    )
    let deck = Deck(name: "One per study day", newCardsPerDay: 1)
    _ = try await store.createDeck(deck)
    _ = try await store.createItem(
        dailyLimitItem("First", deckID: deck.id),
        now: beforeRollover
    )
    _ = try await store.createItem(
        dailyLimitItem("Second", deckID: deck.id),
        now: beforeRollover
    )

    let first = try #require(
        try await store.fetchDueCards(asOf: beforeRollover).first
    )
    _ = try await store.submitReview(
        cardID: first.card.id,
        rating: .good,
        now: beforeRollover
    )

    #expect(try await store.fetchDueCards(asOf: beforeRollover).isEmpty)
    #expect(try await store.fetchDueCards(asOf: afterRollover).count == 1)
}
