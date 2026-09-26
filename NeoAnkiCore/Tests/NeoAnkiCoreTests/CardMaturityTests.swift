import Foundation
import Testing
@testable import NeoAnkiCore

private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func review(
    cardID: UUID,
    day: Double,
    elapsed: Double,
    rating: ReviewRating
) -> ReviewLog {
    ReviewLog(
        cardID: cardID,
        reviewedAt: start.addingTimeInterval(day * 86_400),
        rating: rating,
        elapsedDays: elapsed,
        scheduledDays: elapsed,
        phaseBefore: .review,
        durationMs: 1_000
    )
}

private func card(stability: Double = 30, phase: Phase = .review) -> Card {
    Card(
        itemID: UUID(),
        templateID: UUID(),
        skill: Skill(input: .text, output: .text, operation: .recall),
        memory: MemoryState(stability: stability, reps: 3, phase: phase)
    )
}

@Test func maturityNeedsTwoLongGapRecallsAndThirtyDayStability() {
    let candidate = card()
    let initial = review(cardID: candidate.id, day: 0, elapsed: 0, rating: .good)
    let one = review(cardID: candidate.id, day: 8, elapsed: 8, rating: .good)
    let short = review(cardID: candidate.id, day: 9, elapsed: 1, rating: .easy)
    let two = review(cardID: candidate.id, day: 17, elapsed: 0, rating: .easy)
    var weaker = candidate
    weaker.memory.stability = 29.99

    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: [initial, one, short]) == .learning)
    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: [two, initial, one, short]) == .maintaining)
    let exactOne = review(cardID: candidate.id, day: 7, elapsed: 7, rating: .good)
    let exactTwo = review(cardID: candidate.id, day: 14, elapsed: 7, rating: .good)
    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: [initial, exactOne, exactTwo]) == .maintaining)
    #expect(CardMaturityStatus.evaluate(card: weaker, reviews: [initial, one, two]) == .learning)
    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: [one, two]) == .learning)
}

@Test func failureResetsEvidenceWhileHardPreservesIt() {
    let candidate = card()
    let initial = review(cardID: candidate.id, day: 0, elapsed: 0, rating: .good)
    let one = review(cardID: candidate.id, day: 8, elapsed: 8, rating: .good)
    let two = review(cardID: candidate.id, day: 17, elapsed: 9, rating: .good)
    let hard = review(cardID: candidate.id, day: 25, elapsed: 8, rating: .hard)
    let failure = review(cardID: candidate.id, day: 33, elapsed: 8, rating: .again)
    let repair = review(cardID: candidate.id, day: 33, elapsed: 0, rating: .good)
    var weaker = candidate
    weaker.memory.stability = 10
    var relearning = candidate
    relearning.memory.phase = .relearning

    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: [initial, one, two, hard]) == .maintaining)
    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: [initial, one, two, hard, failure, repair]) == .learning)
    #expect(CardMaturityStatus.evaluate(card: weaker, reviews: [initial, one, two, hard]) == .learning)
    #expect(CardMaturityStatus.evaluate(card: relearning, reviews: [initial, one, two]) == .learning)
}

@Test func inactiveAndNeverReviewedCardsDoNotClaimMaintenance() {
    var candidate = card()
    let logs = [
        review(cardID: candidate.id, day: 8, elapsed: 8, rating: .good),
        review(cardID: candidate.id, day: 17, elapsed: 9, rating: .good),
    ]
    candidate.isSuspended = true
    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: logs) == .inactive)
    candidate.isSuspended = false
    candidate.memory = .new()
    #expect(CardMaturityStatus.evaluate(card: candidate, reviews: logs) == .notStarted)
}

@Test func deckMaturityRequiresEveryActiveCard() {
    let one = MaturitySummary.one(.maintaining)
    let two = one.adding(.one(.notStarted)).adding(.one(.inactive))
    #expect(one.status == .maintaining)
    #expect(two.activeCardCount == 2)
    #expect(two.maintainingCardCount == 1)
    #expect(two.status == .learning)
    #expect(MaturitySummary.one(.inactive).status == .noActiveCards)
}

@Test func storedMaturityFollowsRevertResetAndSuspension() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-maturity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let parent = Deck(name: "Poems")
    let child = Deck(name: "A poem", parentID: parent.id)
    _ = try await store.createDeck(parent)
    _ = try await store.createDeck(child)
    let item = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("First line")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Second line")),
        ],
        deckID: child.id
    )
    _ = try await store.createItem(item, now: start)
    let cardID = try #require((try await store.fetchDueCards(asOf: start)).first?.card.id)
    #expect(try await store.cardMaturityStatus(id: cardID) == .notStarted)

    _ = try await store.submitReview(cardID: cardID, rating: .good, now: start)
    _ = try await store.submitReview(
        cardID: cardID, rating: .good, now: start.addingTimeInterval(8 * 86_400)
    )
    _ = try await store.submitReview(
        cardID: cardID, rating: .good, now: start.addingTimeInterval(17 * 86_400)
    )
    let latestID = try #require(await store.database.fetchActiveReviewLogs(cardID: cardID).last?.id)
    var learned = try await store.card(id: cardID)
    learned.memory.stability = 40
    try await store.applySynchronizedCard(learned)

    #expect(try await store.cardMaturityStatus(id: cardID) == .maintaining)
    #expect(try await store.scopeSummary(scope: .deck(parent.id, includeDescendants: true)).maturity.status == .maintaining)
    #expect(try await store.deckSummaries().first(where: { $0.id == parent.id })?.maturity.status == .maintaining)
    #expect(try await store.cardMaturityDetails(itemID: item.id).first?.status == .maintaining)

    var edited = item
    edited.fields[0] = FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Changed line"))
    _ = try await store.updateItem(edited, now: start.addingTimeInterval(18 * 86_400))
    #expect(try await store.cardMaturityStatus(id: cardID) == .maintaining)

    let unfinished = Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Another line")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Its answer")),
        ],
        deckID: parent.id
    )
    _ = try await store.createItem(unfinished, now: start)
    let unfinishedID = try #require((try await store.cards()).first { $0.itemID == unfinished.id }?.id)
    #expect(try await store.deckSummaries().first(where: { $0.id == child.id })?.maturity.status == .maintaining)
    #expect(try await store.deckSummaries().first(where: { $0.id == parent.id })?.maturity.status == .learning)
    _ = try await store.setCardSuspended(id: unfinishedID, isSuspended: true)
    #expect(try await store.deckSummaries().first(where: { $0.id == parent.id })?.maturity.status == .maintaining)

    try await store.revertReview(reviewLogID: latestID)
    #expect(try await store.cardMaturityStatus(id: cardID) == .learning)
    _ = try await store.setCardSuspended(id: cardID, isSuspended: true)
    #expect(try await store.cardMaturityStatus(id: cardID) == .inactive)
    #expect(try await store.scopeSummary(scope: .deck(parent.id, includeDescendants: true)).maturity.status == .noActiveCards)
    _ = try await store.resetCardProgress(id: cardID)
    #expect(try await store.cardMaturityStatus(id: cardID) == .inactive)
    _ = try await store.setCardSuspended(id: cardID, isSuspended: false)
    #expect(try await store.cardMaturityStatus(id: cardID) == .notStarted)

    let importData = """
    {"itemType":"Basic","rows":[{"Front":"Imported line","Back":"Imported answer"}]}
    """.data(using: .utf8)!
    let imported = try await store.importItemSummaries(
        from: importData,
        adapter: JSONImportAdapter(),
        now: start
    )
    let importedID = try #require(imported.first?.id)
    #expect(try await store.cardMaturityDetails(itemID: importedID).first?.status == .notStarted)
}
