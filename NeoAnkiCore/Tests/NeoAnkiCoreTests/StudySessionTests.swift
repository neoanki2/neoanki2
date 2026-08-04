import Foundation
import Testing
@testable import NeoAnkiCore

private func studyTestStore() async throws -> ItemStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-study-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    return store
}

private func studyItem(_ front: String, deckID: UUID? = nil) -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text(front)),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ],
        deckID: deckID
    )
}

@Test func studyNextIsRetrySafeAndReservationsExcludeOtherSessions() async throws {
    let store = try await studyTestStore()
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    _ = try await store.createItem(studyItem("First"), now: now)
    _ = try await store.createItem(studyItem("Second"), now: now)
    let firstSession = try await store.createStudySession(
        clientID: UUID(), scope: .allDecks, now: now
    )
    let secondSession = try await store.createStudySession(
        clientID: UUID(), scope: .allDecks, now: now
    )

    let first = try #require(try await store.reserveNextStudyCard(
        sessionID: firstSession.id, now: now
    ))
    let retry = try #require(try await store.reserveNextStudyCard(
        sessionID: firstSession.id, now: now.addingTimeInterval(1)
    ))
    let second = try #require(try await store.reserveNextStudyCard(
        sessionID: secondSession.id, now: now
    ))

    #expect(retry.card.id == first.card.id)
    #expect(second.card.id != first.card.id)
    #expect(try await store.studySession(id: firstSession.id).currentCardID == first.card.id)
}

@Test func expiredReservationCanBeClaimedByAnotherSession() async throws {
    let store = try await studyTestStore()
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    _ = try await store.createItem(studyItem("Only"), now: now)
    let firstSession = try await store.createStudySession(
        clientID: UUID(), scope: .allDecks, now: now
    )
    let secondSession = try await store.createStudySession(
        clientID: UUID(), scope: .allDecks, now: now
    )
    let first = try #require(try await store.reserveNextStudyCard(
        sessionID: firstSession.id,
        now: now,
        reservationLifetime: 10
    ))

    #expect(try await store.reserveNextStudyCard(
        sessionID: secondSession.id,
        now: now.addingTimeInterval(9)
    ) == nil)
    let reclaimed = try #require(try await store.reserveNextStudyCard(
        sessionID: secondSession.id,
        now: now.addingTimeInterval(11)
    ))
    #expect(reclaimed.card.id == first.card.id)
    #expect(try await store.studySession(id: firstSession.id).currentCardID == nil)
}

@Test func reservedReviewIsAtomicAndCannotBeSubmittedTwice() async throws {
    let store = try await studyTestStore()
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    _ = try await store.createItem(studyItem("Question"), now: now)
    let session = try await store.createStudySession(
        clientID: UUID(), scope: .allDecks, now: now
    )
    let due = try #require(try await store.reserveNextStudyCard(
        sessionID: session.id, now: now
    ))

    let result = try await store.submitReservedReview(
        sessionID: session.id,
        cardID: due.card.id,
        rating: .good,
        now: now,
        durationMs: 500
    )

    #expect(result.memory.phase != .new)
    #expect(try await store.activeReviewLogCount(for: due.card.id) == 1)
    #expect(try await store.studySession(id: session.id).currentCardID == nil)
    await #expect(throws: DatabaseError.studyConflict(
        "The card is not reserved by this active study session."
    )) {
        try await store.submitReservedReview(
            sessionID: session.id,
            cardID: due.card.id,
            rating: .good,
            now: now
        )
    }
    #expect(try await store.activeReviewLogCount(for: due.card.id) == 1)
}

@Test func endingStudySessionReleasesReservationAndRejectsFurtherWork() async throws {
    let store = try await studyTestStore()
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    _ = try await store.createItem(studyItem("Question"), now: now)
    let session = try await store.createStudySession(
        clientID: UUID(), scope: .allDecks, now: now
    )
    _ = try #require(try await store.reserveNextStudyCard(sessionID: session.id, now: now))

    try await store.endStudySession(id: session.id, now: now.addingTimeInterval(1))

    let ended = try await store.studySession(id: session.id)
    #expect(ended.state == .ended)
    #expect(ended.currentCardID == nil)
    await #expect(throws: DatabaseError.studyConflict("The study session has ended.")) {
        try await store.reserveNextStudyCard(sessionID: session.id, now: now)
    }
}
