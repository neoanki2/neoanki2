import Foundation
import NeoAnkiCore

public protocol LibraryQuerying: Sendable {
    func libraryID() async throws -> UUID
    func coldHomeSnapshot(scope: DeckScope, asOf: Date) async throws -> ColdLibraryHomeSnapshot
    func items(scope: DeckScope) async throws -> [SavedItemSummary]
    func item(id: UUID) async throws -> (item: Item, itemType: ItemType)?
    func dueCards(scope: DeckScope, asOf: Date, limit: Int?) async throws -> [DueCard]
}

public protocol LibraryMutating: Sendable {
    func createItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary
    func updateItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary
    func deleteItem(id: UUID, asOf: Date) async throws -> Bool
}

public protocol LibraryStudying: Sendable {
    func submitReview(
        cardID: UUID,
        rating: ReviewRating,
        asOf: Date,
        durationMilliseconds: Int
    ) async throws -> ReviewSubmission
    func revertReview(id: UUID, asOf: Date) async throws
}

public protocol LibraryChangePersisting: Sendable {
    func currentChangeCursor() async throws -> Int64
    func changes(after cursor: Int64, limit: Int) async throws -> [LibraryChange]
    func createBackup(at destination: URL) async throws
}

public protocol LibraryRepository:
    LibraryQuerying,
    LibraryMutating,
    LibraryStudying,
    LibraryChangePersisting
{}

/// The only Application-layer adapter that knows `ItemStore`. Presentation
/// models receive focused repository capabilities, never the store itself.
public actor SQLiteLibraryRepository: LibraryRepository {
    private let store: ItemStore

    public init(store: ItemStore) {
        self.store = store
    }

    public init(databaseURL: URL, profileID: String = "default") throws {
        store = try ItemStore(databaseURL: databaseURL, profileID: profileID)
    }

    public func libraryID() async throws -> UUID { try await store.libraryID() }

    public func coldHomeSnapshot(
        scope: DeckScope,
        asOf: Date
    ) async throws -> ColdLibraryHomeSnapshot {
        try await store.coldLibraryHomeSnapshot(scope: scope, asOf: asOf)
    }

    public func items(scope: DeckScope) async throws -> [SavedItemSummary] {
        try await store.listItems(scope: scope)
    }

    public func item(id: UUID) async throws -> (item: Item, itemType: ItemType)? {
        try await store.fetchItem(id: id)
    }

    public func dueCards(
        scope: DeckScope,
        asOf: Date,
        limit: Int?
    ) async throws -> [DueCard] {
        try await store.fetchDueCards(scope: scope, asOf: asOf, limit: limit)
    }

    public func createItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary {
        try await store.createItem(item, now: asOf)
    }

    public func updateItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary {
        try await store.updateItem(item, now: asOf)
    }

    public func deleteItem(id: UUID, asOf: Date) async throws -> Bool {
        try await store.deleteItem(id: id, now: asOf)
    }

    public func submitReview(
        cardID: UUID,
        rating: ReviewRating,
        asOf: Date,
        durationMilliseconds: Int
    ) async throws -> ReviewSubmission {
        try await store.submitReviewWithReceipt(
            cardID: cardID,
            rating: rating,
            now: asOf,
            durationMs: durationMilliseconds
        )
    }

    public func revertReview(id: UUID, asOf: Date) async throws {
        try await store.revertReview(reviewLogID: id, now: asOf)
    }

    public func currentChangeCursor() async throws -> Int64 {
        try await store.currentChangeCursor()
    }

    public func changes(after cursor: Int64, limit: Int) async throws -> [LibraryChange] {
        try await store.libraryChanges(after: cursor, limit: limit)
    }

    public func createBackup(at destination: URL) async throws {
        try await store.createValidationDatabaseSnapshot(at: destination)
    }
}
