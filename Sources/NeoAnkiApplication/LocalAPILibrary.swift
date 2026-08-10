import Foundation
import NeoAnkiCore

public final class TemporaryLocalAPILibrary: @unchecked Sendable {
    public let library: any LocalAPILibrary
    private let directory: URL

    init(library: any LocalAPILibrary, directory: URL) {
        self.library = library
        self.directory = directory
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Persistence-independent operations required by the loopback HTTP adapter.
/// HTTP routing may orchestrate these commands, but it cannot reach SQLite or
/// `ItemStore` directly.
public protocol LocalAPILibrary: LibraryRepository {
    func withAPIMutation<T: Sendable>(
        _ operation: @Sendable () async -> T
    ) async -> T

    func apiTransferStateURL() async -> URL
    func createValidationSnapshot(at destination: URL) async throws
    func makeValidationLibrary() async throws -> TemporaryLocalAPILibrary

    func listDecks() async throws -> [Deck]
    func deckDeletionImpact(id: UUID, policy: DeckDeletionPolicy) async throws -> DeckDeletionImpact
    func commitDeckDeletion(
        id: UUID,
        policy: DeckDeletionPolicy,
        asOf: Date
    ) async throws
    func deckResetImpact(id: UUID) async throws -> DeckResetImpact

    func oldestChangeCursor() async throws -> Int64?
    func resourceRevision(
        resourceType: String,
        resourceID: String
    ) async throws -> LibraryResourceRevision?

    func idempotencyClaim(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String
    ) async throws -> IdempotencyClaim?
    func claimIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        resultResourceID: String?,
        asOf: Date
    ) async throws -> IdempotencyClaim
    func completeIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        status: Int,
        responseBody: Data,
        asOf: Date
    ) async throws

    func createStudySession(
        id: UUID,
        clientID: UUID,
        scope: DeckScope,
        asOf: Date
    ) async throws -> StudySessionRecord
    func studySession(id: UUID) async throws -> StudySessionRecord
    func reserveNextStudyCard(
        sessionID: UUID,
        asOf: Date,
        reservationLifetime: TimeInterval
    ) async throws -> DueCard?
    func skipReservedStudyCard(sessionID: UUID, cardID: UUID, asOf: Date) async throws -> Bool
    func endStudySession(id: UUID, asOf: Date) async throws
    func submitReservedReview(
        sessionID: UUID,
        cardID: UUID,
        rating: ReviewRating,
        reviewLogID: UUID,
        asOf: Date,
        durationMilliseconds: Int
    ) async throws -> ReviewSubmission

    func itemRecord(id: UUID) async throws -> LibraryItemRecord
    func itemRecords() async throws -> [LibraryItemRecord]
    func itemRecordsPage(offset: Int, limit: Int) async throws -> [LibraryItemRecord]
    func validateItem(_ item: Item) async throws
    func executeItemBulk(
        _ operations: [ItemBulkOperation],
        dryRun: Bool,
        asOf: Date
    ) async throws -> [ItemBulkOperationResult]
    func renameTag(from source: String, to destination: String, asOf: Date) async throws -> Int
    func removeTag(_ value: String, asOf: Date) async throws -> Int
    func normalizedTagForLookup(_ raw: String) async throws -> String

    func cards() async throws -> [Card]
    func card(id: UUID) async throws -> Card
    func reviewLog(id: UUID) async throws -> ReviewLog
    func hydratedCard(id: UUID) async throws -> DueCard
    func reviewPreviews(cardID: UUID, asOf: Date) async throws -> [ReviewRating: MemoryState]
    func setCardSuspended(id: UUID, isSuspended: Bool) async throws -> Card
    func resetCardProgress(id: UUID, asOf: Date) async throws -> Card

    func itemType(id: UUID) async throws -> ItemType
    func listItemTypes() async throws -> [ItemType]

    func reserveMedia(
        data: Data,
        kind: MediaKind,
        altText: String?,
        reservationID: UUID,
        asOf: Date
    ) async throws -> ReservedMediaAsset
    func mediaAsset(hash: String) async throws -> MediaAsset?
    func mediaBytes(hash: String) async throws -> (MediaAsset, Data)
}

public extension LocalAPILibrary {
    func claimIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        resultResourceID: String? = nil,
        asOf: Date = .now
    ) async throws -> IdempotencyClaim {
        try await claimIdempotency(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash,
            resultResourceID: resultResourceID,
            asOf: asOf
        )
    }

    func completeIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        status: Int,
        responseBody: Data,
        asOf: Date = .now
    ) async throws {
        try await completeIdempotency(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash,
            status: status,
            responseBody: responseBody,
            asOf: asOf
        )
    }

    func createStudySession(
        id: UUID = UUID(),
        clientID: UUID,
        scope: DeckScope,
        asOf: Date = .now
    ) async throws -> StudySessionRecord {
        try await createStudySession(id: id, clientID: clientID, scope: scope, asOf: asOf)
    }

    func reserveNextStudyCard(
        sessionID: UUID,
        asOf: Date = .now,
        reservationLifetime: TimeInterval = 24 * 60 * 60
    ) async throws -> DueCard? {
        try await reserveNextStudyCard(
            sessionID: sessionID,
            asOf: asOf,
            reservationLifetime: reservationLifetime
        )
    }

    func skipReservedStudyCard(
        sessionID: UUID,
        cardID: UUID,
        asOf: Date = .now
    ) async throws -> Bool {
        try await skipReservedStudyCard(sessionID: sessionID, cardID: cardID, asOf: asOf)
    }

    func endStudySession(id: UUID, asOf: Date = .now) async throws {
        try await endStudySession(id: id, asOf: asOf)
    }

    func submitReservedReview(
        sessionID: UUID,
        cardID: UUID,
        rating: ReviewRating,
        reviewLogID: UUID = UUID(),
        asOf: Date = .now,
        durationMilliseconds: Int = 0
    ) async throws -> ReviewSubmission {
        try await submitReservedReview(
            sessionID: sessionID,
            cardID: cardID,
            rating: rating,
            reviewLogID: reviewLogID,
            asOf: asOf,
            durationMilliseconds: durationMilliseconds
        )
    }

    func executeItemBulk(
        _ operations: [ItemBulkOperation],
        dryRun: Bool,
        asOf: Date = .now
    ) async throws -> [ItemBulkOperationResult] {
        try await executeItemBulk(operations, dryRun: dryRun, asOf: asOf)
    }

    func renameTag(
        from source: String,
        to destination: String,
        asOf: Date = .now
    ) async throws -> Int {
        try await renameTag(from: source, to: destination, asOf: asOf)
    }

    func removeTag(_ value: String, asOf: Date = .now) async throws -> Int {
        try await removeTag(value, asOf: asOf)
    }

    func reviewPreviews(
        cardID: UUID,
        asOf: Date = .now
    ) async throws -> [ReviewRating: MemoryState] {
        try await reviewPreviews(cardID: cardID, asOf: asOf)
    }

    func resetCardProgress(id: UUID, asOf: Date = .now) async throws -> Card {
        try await resetCardProgress(id: id, asOf: asOf)
    }

    func reserveMedia(
        data: Data,
        kind: MediaKind,
        altText: String? = nil,
        reservationID: UUID = UUID(),
        asOf: Date = .now
    ) async throws -> ReservedMediaAsset {
        try await reserveMedia(
            data: data,
            kind: kind,
            altText: altText,
            reservationID: reservationID,
            asOf: asOf
        )
    }
}

extension SQLiteLibraryRepository: LocalAPILibrary {
    public func withAPIMutation<T: Sendable>(
        _ operation: @Sendable () async -> T
    ) async -> T {
        await store.acquireExternalMutationSlot()
        let result = await operation()
        await store.releaseExternalMutationSlot()
        return result
    }

    public func apiTransferStateURL() async -> URL { await store.localAPITransferStateURL() }
    public func createValidationSnapshot(at destination: URL) async throws {
        try await store.createValidationDatabaseSnapshot(at: destination)
    }
    public func makeValidationLibrary() async throws -> TemporaryLocalAPILibrary {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-api-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let databaseURL = directory.appendingPathComponent("library.sqlite")
            try await store.createValidationDatabaseSnapshot(at: databaseURL)
            let validationStore = try ItemStore(databaseURL: databaseURL, starterItemTypes: [])
            try await validationStore.bootstrap()
            return TemporaryLocalAPILibrary(
                library: SQLiteLibraryRepository(store: validationStore),
                directory: directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func listDecks() async throws -> [Deck] { try await store.listDecks() }
    public func deckDeletionImpact(
        id: UUID,
        policy: DeckDeletionPolicy
    ) async throws -> DeckDeletionImpact {
        try await store.deckDeletionImpact(id: id, policy: policy)
    }
    public func commitDeckDeletion(
        id: UUID,
        policy: DeckDeletionPolicy,
        asOf: Date
    ) async throws {
        try await store.commitDeckDeletion(id: id, policy: policy, now: asOf)
    }
    public func deckResetImpact(id: UUID) async throws -> DeckResetImpact {
        try await store.deckResetImpact(id: id)
    }

    public func oldestChangeCursor() async throws -> Int64? { try await store.oldestChangeCursor() }
    public func resourceRevision(
        resourceType: String,
        resourceID: String
    ) async throws -> LibraryResourceRevision? {
        try await store.resourceRevision(resourceType: resourceType, resourceID: resourceID)
    }

    public func idempotencyClaim(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String
    ) async throws -> IdempotencyClaim? {
        try await store.idempotencyClaim(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash
        )
    }
    public func claimIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        resultResourceID: String?,
        asOf: Date
    ) async throws -> IdempotencyClaim {
        try await store.claimIdempotency(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash,
            resultResourceID: resultResourceID,
            now: asOf
        )
    }
    public func completeIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        status: Int,
        responseBody: Data,
        asOf: Date
    ) async throws {
        try await store.completeIdempotency(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash,
            status: status,
            responseBody: responseBody,
            now: asOf
        )
    }

    public func createStudySession(
        id: UUID,
        clientID: UUID,
        scope: DeckScope,
        asOf: Date
    ) async throws -> StudySessionRecord {
        try await store.createStudySession(id: id, clientID: clientID, scope: scope, now: asOf)
    }
    public func studySession(id: UUID) async throws -> StudySessionRecord {
        try await store.studySession(id: id)
    }
    public func reserveNextStudyCard(
        sessionID: UUID,
        asOf: Date,
        reservationLifetime: TimeInterval
    ) async throws -> DueCard? {
        try await store.reserveNextStudyCard(
            sessionID: sessionID,
            now: asOf,
            reservationLifetime: reservationLifetime
        )
    }
    public func skipReservedStudyCard(
        sessionID: UUID,
        cardID: UUID,
        asOf: Date
    ) async throws -> Bool {
        try await store.skipReservedStudyCard(sessionID: sessionID, cardID: cardID, now: asOf)
    }
    public func endStudySession(id: UUID, asOf: Date) async throws {
        try await store.endStudySession(id: id, now: asOf)
    }
    public func submitReservedReview(
        sessionID: UUID,
        cardID: UUID,
        rating: ReviewRating,
        reviewLogID: UUID,
        asOf: Date,
        durationMilliseconds: Int
    ) async throws -> ReviewSubmission {
        try await store.submitReservedReview(
            sessionID: sessionID,
            cardID: cardID,
            rating: rating,
            reviewLogID: reviewLogID,
            now: asOf,
            durationMs: durationMilliseconds
        )
    }

    public func itemRecord(id: UUID) async throws -> LibraryItemRecord {
        try await store.itemRecord(id: id)
    }
    public func itemRecords() async throws -> [LibraryItemRecord] { try await store.itemRecords() }
    public func itemRecordsPage(offset: Int, limit: Int) async throws -> [LibraryItemRecord] {
        try await store.itemRecordsPage(offset: offset, limit: limit)
    }
    public func validateItem(_ item: Item) async throws { try await store.validateItem(item) }
    public func executeItemBulk(
        _ operations: [ItemBulkOperation],
        dryRun: Bool,
        asOf: Date
    ) async throws -> [ItemBulkOperationResult] {
        try await store.executeItemBulk(operations, dryRun: dryRun, now: asOf)
    }
    public func renameTag(
        from source: String,
        to destination: String,
        asOf: Date
    ) async throws -> Int {
        try await store.renameTag(from: source, to: destination, now: asOf)
    }
    public func removeTag(_ value: String, asOf: Date) async throws -> Int {
        try await store.removeTag(value, now: asOf)
    }
    public func normalizedTagForLookup(_ raw: String) async throws -> String {
        try await store.normalizedTagForLookup(raw)
    }

    public func cards() async throws -> [Card] { try await store.cards() }
    public func card(id: UUID) async throws -> Card { try await store.card(id: id) }
    public func reviewLog(id: UUID) async throws -> ReviewLog { try await store.reviewLog(id: id) }
    public func hydratedCard(id: UUID) async throws -> DueCard { try await store.hydratedCard(id: id) }
    public func reviewPreviews(
        cardID: UUID,
        asOf: Date
    ) async throws -> [ReviewRating: MemoryState] {
        try await store.reviewPreviews(cardID: cardID, now: asOf)
    }
    public func setCardSuspended(id: UUID, isSuspended: Bool) async throws -> Card {
        try await store.setCardSuspended(id: id, isSuspended: isSuspended)
    }
    public func resetCardProgress(id: UUID, asOf: Date) async throws -> Card {
        try await store.resetCardProgress(id: id, now: asOf)
    }

    public func itemType(id: UUID) async throws -> ItemType { try await store.itemType(id: id) }
    public func listItemTypes() async throws -> [ItemType] { try await store.listItemTypes() }

    public func reserveMedia(
        data: Data,
        kind: MediaKind,
        altText: String?,
        reservationID: UUID,
        asOf: Date
    ) async throws -> ReservedMediaAsset {
        try await store.reserveMedia(
            data: data,
            kind: kind,
            altText: altText,
            reservationID: reservationID,
            now: asOf
        )
    }
    public func mediaAsset(hash: String) async throws -> MediaAsset? {
        try await store.mediaAsset(hash: hash)
    }
    public func mediaBytes(hash: String) async throws -> (MediaAsset, Data) {
        try await store.mediaBytes(hash: hash)
    }
}
