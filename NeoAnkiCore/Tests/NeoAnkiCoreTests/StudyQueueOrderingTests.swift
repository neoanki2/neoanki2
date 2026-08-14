import Foundation
import Testing
@testable import NeoAnkiCore

@Test(arguments: [Phase.review, .learning, .relearning])
func dueQueuesPutLearnedCardsBeforeEarlierNewMaterial(phase: Phase) async throws {
    let store = try await studyQueueStore()
    let deck = Deck(name: "Mixed queue")
    _ = try await store.createDeck(deck)
    let pair = try await makeNewAndLearnedPair(in: store, deckID: deck.id, phase: phase)

    let allDecks = try await store.fetchDueCards(asOf: pair.asOf)
    let deckOnly = try await store.fetchDueCards(
        scope: .deck(deck.id, includeDescendants: false),
        asOf: pair.asOf
    )
    let firstOnly = try await store.fetchDueCards(asOf: pair.asOf, limit: 1)
    let firstTwo = try await store.fetchDueCards(asOf: pair.asOf, limit: 2)

    #expect(allDecks.map(\.card.id) == [pair.learnedCardID, pair.newCardID])
    #expect(deckOnly.map(\.card.id) == [pair.learnedCardID, pair.newCardID])
    #expect(firstOnly.map(\.card.id) == [pair.learnedCardID])
    #expect(firstTwo.map(\.card.id) == [pair.learnedCardID, pair.newCardID])
}

@Test(arguments: [Phase.review, .learning, .relearning])
func unassignedDueQueuePutsLearnedCardsBeforeEarlierNewMaterial(phase: Phase) async throws {
    let store = try await studyQueueStore()
    let pair = try await makeNewAndLearnedPair(in: store, deckID: nil, phase: phase)

    let due = try await store.fetchDueCards(scope: .unassigned, asOf: pair.asOf)
    let firstOnly = try await store.fetchDueCards(
        scope: .unassigned,
        asOf: pair.asOf,
        limit: 1
    )
    let negativeLimit = try await store.fetchDueCards(
        scope: .unassigned,
        asOf: pair.asOf,
        limit: -1
    )

    #expect(due.map(\.card.id) == [pair.learnedCardID, pair.newCardID])
    #expect(firstOnly.map(\.card.id) == [pair.learnedCardID])
    #expect(negativeLimit.map(\.card.id) == [pair.learnedCardID, pair.newCardID])
}

@Test(arguments: [Phase.review, .learning, .relearning])
func studySessionReservesALearnedCardBeforeEarlierNewMaterial(phase: Phase) async throws {
    let store = try await studyQueueStore()
    let deck = Deck(name: "Session queue")
    _ = try await store.createDeck(deck)
    let pair = try await makeNewAndLearnedPair(in: store, deckID: deck.id, phase: phase)
    let session = try await store.createStudySession(
        clientID: UUID(),
        scope: .allDecks,
        now: pair.asOf
    )

    let reserved = try await store.reserveNextStudyCard(
        sessionID: session.id,
        now: pair.asOf
    )

    #expect(reserved?.card.id == pair.learnedCardID)
}

private struct StudyQueuePair {
    let newCardID: UUID
    let learnedCardID: UUID
    let asOf: Date
}

private func makeNewAndLearnedPair(
    in store: ItemStore,
    deckID: UUID?,
    phase: Phase
) async throws -> StudyQueuePair {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let newItem = try await store.createItem(
        studyQueueItem("New material", deckID: deckID),
        now: start
    )
    let learnedItem = try await store.createItem(
        studyQueueItem("Old material", deckID: deckID),
        now: start.addingTimeInterval(1)
    )
    let initial = try await store.fetchDueCards(asOf: start.addingTimeInterval(1))
    let newCard = try #require(initial.first { $0.item.id == newItem.id })
    let learnedCard = try #require(initial.first { $0.item.id == learnedItem.id })
    var submission = try await store.submitReviewWithReceipt(
        cardID: learnedCard.card.id,
        rating: phase == .learning ? .again : .good,
        now: start.addingTimeInterval(1)
    )
    if phase == .relearning {
        submission = try await store.submitReviewWithReceipt(
            cardID: learnedCard.card.id,
            rating: .again,
            now: submission.memory.due
        )
    }

    #expect(submission.memory.phase == phase)
    #expect(submission.memory.due > newCard.card.memory.due)
    return StudyQueuePair(
        newCardID: newCard.card.id,
        learnedCardID: learnedCard.card.id,
        asOf: submission.memory.due
    )
}

private func studyQueueStore() async throws -> ItemStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    return store
}

private func studyQueueItem(_ title: String, deckID: UUID?) -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text(title)),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ],
        deckID: deckID
    )
}
