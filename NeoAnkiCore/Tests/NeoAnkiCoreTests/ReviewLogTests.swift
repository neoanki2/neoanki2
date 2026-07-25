import Foundation
import Testing
@testable import NeoAnkiCore

@Test func reviewLogStoresReviewMetadata() {
    let cardID = UUID()
    let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let log = ReviewLog(
        cardID: cardID,
        reviewedAt: reviewedAt,
        rating: .good,
        elapsedDays: 0,
        scheduledDays: 0,
        phaseBefore: .new,
        durationMs: 1500
    )

    #expect(log.cardID == cardID)
    #expect(log.reviewedAt == reviewedAt)
    #expect(log.rating == .good)
    #expect(log.elapsedDays == 0)
    #expect(log.scheduledDays == 0)
    #expect(log.phaseBefore == .new)
    #expect(log.durationMs == 1500)
}

@Test func reviewLogCodableRoundTrip() throws {
    let original = ReviewLog(
        cardID: UUID(),
        reviewedAt: Date(timeIntervalSince1970: 1_700_000_100),
        rating: .hard,
        elapsedDays: 2.5,
        scheduledDays: 3,
        phaseBefore: .review,
        durationMs: 800
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ReviewLog.self, from: data)

    #expect(decoded == original)
}

@Test func reviewLogEqualityUsesAllFields() {
    let id = UUID()
    let cardID = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    let a = ReviewLog(
        id: id,
        cardID: cardID,
        reviewedAt: date,
        rating: .again,
        elapsedDays: 1,
        scheduledDays: 1,
        phaseBefore: .learning,
        durationMs: 100
    )
    let b = ReviewLog(
        id: id,
        cardID: cardID,
        reviewedAt: date,
        rating: .again,
        elapsedDays: 1,
        scheduledDays: 1,
        phaseBefore: .learning,
        durationMs: 100
    )
    let c = ReviewLog(
        id: UUID(),
        cardID: cardID,
        reviewedAt: date,
        rating: .again,
        elapsedDays: 1,
        scheduledDays: 1,
        phaseBefore: .learning,
        durationMs: 100
    )

    #expect(a == b)
    #expect(a != c)
}
