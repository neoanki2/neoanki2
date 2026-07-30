import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

@Test func unlimitedAllDecksEligibilityUsesDirectDueIndexPlan() async throws {
    let url = studyQueryPlanDatabaseURL()
    let database = try SQLiteDatabase(path: url)
    try await database.migrate()

    let plan = try await database.dueEligibilityQueryPlan(
        scope: .all,
        asOf: Date(timeIntervalSince1970: 1_800_000_000),
        studyDay: "2027-01-15"
    )

    #expect(plan.contains { $0.contains("idx_cards_due_at") })
    #expect(!plan.contains { $0.contains("deck_ancestry") })
    #expect(!plan.contains { $0.contains("new_card_introductions") })
}

@Test func singleLimitedDeckUsesBoundedActiveNewIndex() async throws {
    let url = studyQueryPlanDatabaseURL()
    let database = try SQLiteDatabase(path: url)
    try await database.migrate()
    try await database.insertDeck(Deck(name: "Limited", newCardsPerDay: 20))

    let plan = try await database.dueEligibilityQueryPlan(
        scope: .all,
        asOf: Date(timeIntervalSince1970: 1_800_000_000),
        studyDay: "2027-01-15"
    )

    #expect(plan.contains { $0.contains("allowed_new") })
    #expect(!plan.contains { $0.contains("new_positions") })
}

@Test func ancestorLimitKeepsScopedDeckOnRankedEligibilityPlan() async throws {
    let url = studyQueryPlanDatabaseURL()
    let database = try SQLiteDatabase(path: url)
    try await database.migrate()
    let parent = Deck(name: "Limited parent", newCardsPerDay: 20)
    let child = Deck(name: "Limited child", parentID: parent.id, newCardsPerDay: 10)
    try await database.insertDeck(parent)
    try await database.insertDeck(child)

    let plan = try await database.dueEligibilityQueryPlan(
        scope: .decks([child.id]),
        asOf: Date(timeIntervalSince1970: 1_800_000_000),
        studyDay: "2027-01-15"
    )

    #expect(plan.contains {
        $0.contains("idx_new_card_introductions_day_deck_log")
            && $0.contains("study_day=?")
    })
}

@Test func unlimitedScopedDeckUsesDirectEligibilityPlan() async throws {
    let url = studyQueryPlanDatabaseURL()
    let database = try SQLiteDatabase(path: url)
    try await database.migrate()
    let parent = Deck(name: "Unlimited parent")
    let child = Deck(name: "Unlimited child", parentID: parent.id)
    try await database.insertDeck(parent)
    try await database.insertDeck(child)

    let plan = try await database.dueEligibilityQueryPlan(
        scope: .decks([child.id]),
        asOf: Date(timeIntervalSince1970: 1_800_000_000),
        studyDay: "2027-01-15"
    )

    #expect(plan.contains { $0.contains("idx_cards_deck_due") })
    #expect(!plan.contains { $0.contains("new_card_introductions") })
}

@Test func unlimitedFastPathMatchesLimitedEligibilityOrderAndCounts() async throws {
    let url = studyQueryPlanDatabaseURL()
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    var deck = Deck(name: "Deck")
    _ = try await store.createDeck(deck)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    for index in 0..<4 {
        _ = try await store.createItem(
            studyQueryPlanItem("Deck \(index)", deckID: deck.id),
            now: now
        )
    }
    _ = try await store.createItem(studyQueryPlanItem("Unassigned"), now: now)

    let unlimitedDue = try await store.fetchDueCards(asOf: now)
    let unlimitedCards = unlimitedDue.map(\.card.id)
    let unlimitedCount = try await store.dueCount(asOf: now)

    deck.newCardsPerDay = 100
    _ = try await store.updateDeck(deck)

    let limitedDue = try await store.fetchDueCards(asOf: now)
    let limitedCards = limitedDue.map(\.card.id)
    let limitedCount = try await store.dueCount(asOf: now)

    #expect(unlimitedCards == limitedCards)
    #expect(unlimitedCount == limitedCount)

    _ = try await store.createDeck(Deck(name: "Empty second limiter", newCardsPerDay: 0))
    let fallbackDue = try await store.fetchDueCards(asOf: now)
    #expect(fallbackDue.map(\.card.id) == limitedCards)
    #expect(try await store.dueCount(asOf: now) == limitedCount)
}

@Test(arguments: [7, 19, 41, 73, 101, 149])
func singleLimiterMatchesGeneralFallbackAcrossRandomHierarchies(seed: UInt64) async throws {
    var random = StudyEligibilityRandom(seed: seed)
    let url = studyQueryPlanDatabaseURL()
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let now = Date(timeIntervalSince1970: 1_800_000_000 + Double(seed * 86_400))
    let tomorrow = now.addingTimeInterval(86_400)
    let root = Deck(name: "Limited root", newCardsPerDay: random.int(in: 1...6))
    let firstChild = Deck(name: "First child", parentID: root.id)
    let secondChild = Deck(name: "Second child", parentID: root.id)
    let grandchild = Deck(name: "Grandchild", parentID: firstChild.id)
    let outside = Deck(name: "Unlimited outside")
    for deck in [root, firstChild, secondChild, grandchild, outside] {
        _ = try await store.createDeck(deck)
    }

    let destinations: [UUID?] = [
        root.id,
        firstChild.id,
        secondChild.id,
        grandchild.id,
        outside.id,
        nil,
    ]
    for index in 0..<random.int(in: 18...30) {
        let deckID = destinations[random.int(in: 0...(destinations.count - 1))]
        _ = try await store.createItem(
            studyQueryPlanItem("Seed \(seed) item \(index)", deckID: deckID),
            now: now
        )
    }

    let initiallyLimited = try await store.fetchDueCards(
        scope: .deck(root.id, includeDescendants: true),
        asOf: now
    )
    var reviewLogIDs: [UUID] = []
    for entry in initiallyLimited.prefix(random.int(in: 0...initiallyLimited.count)) {
        let receipt = try await store.submitReviewWithReceipt(
            cardID: entry.card.id,
            rating: random.bool() ? .good : .again,
            now: now
        )
        reviewLogIDs.append(receipt.reviewLogID)
    }
    for reviewLogID in reviewLogIDs where random.bool() {
        try await store.revertReview(reviewLogID: reviewLogID, now: now)
    }

    let optimizedNow = try await studyDueIDs(in: store, asOf: now)
    let optimizedTomorrow = try await studyDueIDs(in: store, asOf: tomorrow)
    let optimizedNowCount = try await store.dueCount(asOf: now)
    let optimizedTomorrowCount = try await store.dueCount(asOf: tomorrow)
    let optimizedSummary = try await store.scopeSummary(scope: .allDecks, asOf: now)

    _ = try await store.createDeck(
        Deck(name: "Empty fallback limiter", newCardsPerDay: random.int(in: 0...4))
    )

    #expect(try await studyDueIDs(in: store, asOf: now) == optimizedNow)
    #expect(try await studyDueIDs(in: store, asOf: tomorrow) == optimizedTomorrow)
    #expect(try await store.dueCount(asOf: now) == optimizedNowCount)
    #expect(try await store.dueCount(asOf: tomorrow) == optimizedTomorrowCount)
    #expect(try await store.scopeSummary(scope: .allDecks, asOf: now) == optimizedSummary)
}

@Test func limiterPlanningAndEligibilityConsumptionShareOneReadSnapshot() async throws {
    let url = studyQueryPlanDatabaseURL()
    let store = try ItemStore(databaseURL: url)
    try await store.bootstrap()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let deck = Deck(name: "One", newCardsPerDay: 1)
    _ = try await store.createDeck(deck)
    for index in 0..<2 {
        _ = try await store.createItem(
            studyQueryPlanItem("Snapshot \(index)", deckID: deck.id),
            now: now
        )
    }
    try studyExecuteSQL("PRAGMA journal_mode = WAL;", at: url)
    let reader = try SQLiteDatabase(path: url)
    try await reader.migrate()
    let studyDay = StudyDay.key(
        for: now,
        rolloverMinutes: StudyDay.defaultRolloverMinutes
    )

    let duringCommit = try await reader.countDueCardsSnapshotDiagnostic(
        asOf: now,
        studyDay: studyDay
    ) {
        try studyExecuteSQL(
            "UPDATE decks SET new_cards_per_day = NULL WHERE id = '\(deck.id.uuidString)';",
            at: url
        )
    }

    #expect(duringCommit == 1)
    #expect(try await reader.countDueCards(asOf: now, studyDay: studyDay) == 2)
}

private func studyQueryPlanDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-query-plan-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func studyQueryPlanItem(_ title: String, deckID: UUID? = nil) -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text(title)),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ],
        deckID: deckID
    )
}

private func studyDueIDs(in store: ItemStore, asOf now: Date) async throws -> [UUID] {
    let due = try await store.fetchDueCards(asOf: now)
    return due.map(\.card.id)
}

private func studyExecuteSQL(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &database) == SQLITE_OK,
          let database
    else {
        throw DatabaseError.openFailed("Could not open study query-plan test database.")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(database)))
    }
}

private struct StudyEligibilityRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return range.lowerBound + Int(state % UInt64(range.count))
    }

    mutating func bool() -> Bool {
        int(in: 0...1) == 1
    }
}
