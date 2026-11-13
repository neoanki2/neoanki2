import Foundation
import Testing
@testable import NeoAnkiCore

private struct SchedulingSyncFixture {
    let url: URL
    let store: ItemStore
    let database: SQLiteDatabase
    let original: Card
    let reviewed: Card
    let review: SynchronizedReviewRecord

    static func make() async throws -> Self {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synced-schedule-\(UUID())/library.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try ItemStore(databaseURL: url)
        try await store.bootstrap()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ])
        try await store.createItem(item, now: now)
        let original = try #require(try await store.fetchDueCards(asOf: now).first?.card)
        let submission = try await store.submitReviewWithReceipt(cardID: original.id, rating: .easy, now: now)
        let reviewed = try await store.card(id: original.id)
        let review = try await store.synchronizedReviewRecord(id: submission.reviewLogID)
        return Self(url: url, store: store, database: try SQLiteDatabase(path: url),
                    original: original, reviewed: reviewed, review: review)
    }
}

struct SyncedReviewSchedulingTests {
    @Test func staleCardCannotReplaceNewerReviewRegardlessOfBatchOrder() async throws {
        let f = try await SchedulingSyncFixture.make()
        defer { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
        for mutations: [SynchronizedLibraryMutation] in [
            [.card(f.original), .review(f.review)], [.review(f.review), .card(f.original)],
            [.card(f.original)],
        ] {
            try await f.store.applySynchronizedBatch(mutations)
            #expect(try await f.store.card(id: f.original.id).memory == f.reviewed.memory)
            #expect(try await f.store.scopeSummary(scope: .allDecks, asOf: f.review.log.reviewedAt).dueNow == 0)
        }
    }

    @Test func reviewOnlyDeliveryRepairsScheduleAndPreservesCardSettings() async throws {
        let f = try await SchedulingSyncFixture.make()
        defer { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
        var stale = f.original
        stale.isSuspended = true
        try await f.database.upsertSynchronizedCard(stale)
        try await f.store.applySynchronizedBatch([.review(f.review)])
        let repaired = try await f.store.card(id: stale.id)
        #expect(repaired.memory == f.reviewed.memory)
        #expect(repaired.isSuspended)
    }

    @Test func bootstrapRepairsAlreadyAcknowledgedStaleSchedule() async throws {
        let f = try await SchedulingSyncFixture.make()
        defer { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
        try await f.database.upsertSynchronizedCard(f.original)
        let reopened = try ItemStore(databaseURL: f.url)
        try await reopened.bootstrap()
        #expect(try await reopened.card(id: f.original.id).memory == f.reviewed.memory)
        let cursor = try await f.database.currentChangeCursor()
        try await reopened.bootstrap()
        #expect(try await f.database.currentChangeCursor() == cursor)
    }

    @Test func lateReviewedSnapshotCannotResurrectUndoneReview() async throws {
        let f = try await SchedulingSyncFixture.make()
        defer { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
        let revert = ReviewRevertRecord(id: UUID(), reviewLogID: f.review.log.id,
                                       revertedAt: f.review.log.reviewedAt.addingTimeInterval(1))
        try await f.store.applySynchronizedBatch([.reviewRevert(revert), .card(f.reviewed)])
        #expect(try await f.store.card(id: f.original.id).memory == f.review.memoryBefore)
        try await f.store.applySynchronizedBatch([.card(f.reviewed)])
        #expect(try await f.store.card(id: f.original.id).memory == f.review.memoryBefore)
    }

    @Test func undoOfLatestReviewRetainsPreviousActiveGrade() async throws {
        let f = try await SchedulingSyncFixture.make()
        defer { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
        var replayed = f.reviewed
        replayed.memory.due = replayed.memory.due.addingTimeInterval(3600)
        try await f.store.applySynchronizedBatch([.card(replayed)])
        let second = try await f.store.submitReviewWithReceipt(
            cardID: f.original.id, rating: .good,
            now: f.review.log.reviewedAt.addingTimeInterval(86_400)
        )
        let latestCard = try await f.store.card(id: f.original.id)
        let revert = ReviewRevertRecord(id: UUID(), reviewLogID: second.reviewLogID,
                                       revertedAt: f.review.log.reviewedAt.addingTimeInterval(86_401))
        try await f.store.applySynchronizedBatch([.card(latestCard), .reviewRevert(revert)])
        #expect(try await f.store.card(id: f.original.id).memory == replayed.memory)
    }

    @Test func repairRespectsSchedulingResetAndSameReviewParameterReplay() async throws {
        let f = try await SchedulingSyncFixture.make()
        defer { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
        var replayed = f.reviewed
        replayed.memory.due = replayed.memory.due.addingTimeInterval(3600)
        try await f.store.applySynchronizedBatch([.card(replayed)])
        #expect(try await f.store.card(id: replayed.id).memory == replayed.memory)
        var reset = f.original
        reset.schedulingHistoryOrigin = f.review.log.reviewedAt.addingTimeInterval(1)
        reset.memory = .new(due: reset.schedulingHistoryOrigin!)
        try await f.store.applySynchronizedBatch([.card(reset), .review(f.review)])
        #expect(try await f.store.card(id: reset.id).memory == reset.memory)
    }
}
