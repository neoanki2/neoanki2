import Foundation
import NeoAnkiCore

// MARK: - Application-facing capabilities

/// Startup operations owned by the library boundary rather than presentation code.
public protocol LibraryBootstrapping: Sendable {
    func bootstrap() async throws
    func coldHomeSnapshot(scope: DeckScope, asOf: Date) async throws -> ColdLibraryHomeSnapshot
    func mediaStore() async -> MediaStore?
}

/// Read models needed by library, browse, and item-detail presentation.
public protocol LibraryBrowsing: Sendable {
    func libraryID() async throws -> UUID
    func loadItemTypes() async throws -> ItemTypeLoadResult
    func loadItemTypeCatalog() async throws -> ItemTypeCatalog
    func effectiveItemTypePolicy(for deckID: UUID) async throws -> DeckItemTypePolicy?
    func items(
        scope: DeckScope,
        sort: ItemSortOrder,
        search: String
    ) async throws -> [SavedItemSummary]
    func item(id: UUID) async throws -> (item: Item, itemType: ItemType)?
    func itemBrowseSchedules(itemIDs: [UUID]) async throws -> [UUID: ItemBrowseSchedule]
    func scopeSummary(scope: DeckScope, asOf: Date) async throws -> ScopeSummary
    func itemRecordsPage(offset: Int, limit: Int) async throws -> [LibraryItemRecord]
}

/// Item commands exposed as application operations, not persistence primitives.
public protocol LibraryItemMutating: Sendable {
    func createItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary
    func updateItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary
    func deleteItem(id: UUID, asOf: Date) async throws -> Bool
    func deleteAllUnassignedItems(asOf: Date) async throws -> Int
    func moveItem(id: UUID, to deckID: UUID?) async throws -> Bool
    func performBulkItemOperations(_ operations: [ItemBulkOperation], asOf: Date) async throws -> [ItemBulkOperationResult]
    func reserveMedia(data: Data, kind: MediaKind, altText: String, asOf: Date) async throws -> ReservedMediaAsset
}

public protocol LibraryDeckManaging: Sendable {
    func deck(id: UUID) async throws -> Deck
    func deckSummaries(asOf: Date) async throws -> [DeckSummary]
    func createDeck(_ deck: Deck) async throws -> Deck
    func updateDeck(_ deck: Deck) async throws -> Deck
    func deleteDeck(id: UUID) async throws -> Bool
    func resetDeckProgress(id: UUID, asOf: Date) async throws -> Int
    func deckDeletionImpact(id: UUID, policy: DeckDeletionPolicy) async throws -> DeckDeletionImpact
    func commitDeckDeletion(id: UUID, policy: DeckDeletionPolicy, asOf: Date) async throws
    func deckResetImpact(id: UUID) async throws -> DeckResetImpact
}

public protocol LibraryItemTypeManaging: Sendable {
    func createItemType(_ itemType: ItemType) async throws -> ItemType
    func updateItemType(_ itemType: ItemType, asOf: Date) async throws -> ItemType
    func duplicateItemType(id: UUID, name: String) async throws -> ItemType
    func repairItemTypeDefinition(id: UUID, asOf: Date) async throws -> ItemType
    func countItems(itemTypeID: UUID) async throws -> Int
    func deleteItemType(id: UUID) async throws -> Bool
}

public protocol LibraryItemTypeEditingSafeguarding: Sendable {
    func itemTypeEditingImpact(id: UUID) async throws -> ItemTypeEditingImpact
    func unlockItemType(id: UUID) async throws -> ItemType
    func itemTypeSchemaChangeImpact(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeSchemaChangeImpact
}

public protocol LibraryStudying: Sendable {
    func dueCount(scope: DeckScope, asOf: Date) async throws -> Int
    func dueCards(scope: DeckScope, asOf: Date, limit: Int?) async throws -> [DueCard]
    func submitReview(
        cardID: UUID,
        rating: ReviewRating,
        asOf: Date,
        durationMilliseconds: Int
    ) async throws -> ReviewSubmission
    func revertReview(id: UUID, asOf: Date) async throws
}

/// Persistent, local-only learner audio responses. Kept separate from graded
/// study operations so feature code cannot accidentally manufacture reviews.
public protocol LibraryStudyResponses: Sendable {
    func completeAudioSubmission(
        _ draft: StudyResponseDraft,
        submittedAt: Date
    ) async throws -> StudyResponse
    func studyResponses(matching query: StudyResponseQuery) async throws -> [StudyResponse]
    func studyResponse(id: UUID) async throws -> StudyResponse
    func studyResponseMediaBytes(id: UUID) async throws -> (StudyResponse, MediaAsset, Data)
    func deleteStudyResponse(id: UUID, asOf: Date) async throws -> Bool
    func ordinaryMediaReferenceCount(hash: String) async throws -> Int
    func isStudyResponseMediaHash(_ hash: String) async throws -> Bool
    func studyResponseCount(cardIDs: Set<UUID>) async throws -> Int
    func studyResponseCount(itemIDs: Set<UUID>) async throws -> Int
    func studyResponseCount(templateIDs: Set<UUID>) async throws -> Int
}

public protocol LibraryScheduling: Sendable {
    func studyDayRolloverMinutes() async throws -> Int
    func setStudyDayRolloverMinutes(_ minutes: Int) async throws
    func optimizeSchedulingIfNeeded(asOf: Date) async throws -> FSRSOptimizationResult?
}

/// High-level import operations keep parser and persistence details behind the boundary.
public protocol LibraryImporting: Sendable {
    func importJSONItems(
        from data: Data,
        itemTypeID: UUID?,
        context: ImportContext,
        asOf: Date
    ) async throws -> [SavedItemSummary]
    func importCSVItems(
        from data: Data,
        itemTypeID: UUID?,
        itemTypeName: String,
        context: ImportContext,
        asOf: Date
    ) async throws -> [SavedItemSummary]
}

/// Portable formats are workflows. Callers should not need access to the database actor.
public protocol LibraryTransferring: Sendable {
    func importPortableDeck(
        from source: URL,
        conflictResolution: PortableDeckTypeConflictResolution
    ) async throws -> PortableDeckImportResult
    func importAuthoredDeck(from source: URL) async throws -> PortableDeckImportResult
    func importAuthoredItems(from source: URL, into deckID: UUID) async throws -> PortableDeckImportResult
    func exportPortableDeck(id: UUID, to destination: URL) async throws
}

public protocol LibraryChangePersisting: Sendable {
    func currentChangeCursor() async throws -> Int64
    func changes(after cursor: Int64, limit: Int) async throws -> [LibraryChange]
    func createBackup(at destination: URL) async throws
    func verifyBackup(at destination: URL) async throws
}

public extension LibraryChangePersisting {
    func verifyBackup(at destination: URL) async throws {
        let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

/// Complete native-client boundary. Feature models should request the smallest
/// constituent capability they need; the composition root owns this aggregate.
public protocol LibraryRepository:
    LibraryBootstrapping,
    LibraryBrowsing,
    LibraryItemMutating,
    LibraryDeckManaging,
    LibraryItemTypeManaging,
    LibraryStudying,
    LibraryStudyResponses,
    LibraryScheduling,
    LibraryImporting,
    LibraryTransferring,
    LibraryChangePersisting
{}

/// Debug fixture operations used to seed deterministic UI scenarios without
/// giving the executable direct access to the persistence actor.
public protocol LibraryScenarioSeeding: LibraryRepository {
    func corruptItemTypeDefinitionForTesting(id: UUID) async throws
}

// MARK: - Convenience defaults

public extension LibraryBrowsing {
    func listItems(
        scope: DeckScope = .allDecks,
        sort: ItemSortOrder = .createdAscending,
        search: String = ""
    ) async throws -> [SavedItemSummary] {
        try await items(scope: scope, sort: sort, search: search)
    }

    func fetchItem(id: UUID) async throws -> (item: Item, itemType: ItemType)? {
        try await item(id: id)
    }

    func items(
        scope: DeckScope = .allDecks,
        sort: ItemSortOrder = .createdAscending,
        search: String = ""
    ) async throws -> [SavedItemSummary] {
        try await items(scope: scope, sort: sort, search: search)
    }

    func scopeSummary(
        scope: DeckScope = .allDecks,
        asOf: Date = .now
    ) async throws -> ScopeSummary {
        try await scopeSummary(scope: scope, asOf: asOf)
    }
}

public extension LibraryItemMutating {
    func createItem(_ item: Item, asOf: Date = .now) async throws -> SavedItemSummary {
        try await createItem(item, asOf: asOf)
    }

    func updateItem(_ item: Item, asOf: Date = .now) async throws -> SavedItemSummary {
        try await updateItem(item, asOf: asOf)
    }

    func deleteItem(id: UUID, asOf: Date = .now) async throws -> Bool {
        try await deleteItem(id: id, asOf: asOf)
    }

    func deleteAllUnassignedItems(asOf: Date = .now) async throws -> Int {
        try await deleteAllUnassignedItems(asOf: asOf)
    }
}

public extension LibraryDeckManaging {
    func deckSummaries(asOf: Date = .now) async throws -> [DeckSummary] {
        try await deckSummaries(asOf: asOf)
    }

    func resetDeckProgress(id: UUID, asOf: Date = .now) async throws -> Int {
        try await resetDeckProgress(id: id, asOf: asOf)
    }
}

public extension LibraryItemTypeManaging {
    func updateItemType(_ itemType: ItemType, asOf: Date = .now) async throws -> ItemType {
        try await updateItemType(itemType, asOf: asOf)
    }

    func repairItemTypeDefinition(id: UUID, asOf: Date = .now) async throws -> ItemType {
        try await repairItemTypeDefinition(id: id, asOf: asOf)
    }
}

public extension LibraryStudying {
    func dueCards(
        scope: DeckScope,
        asOf: Date,
        limit: Int? = nil
    ) async throws -> [DueCard] {
        try await dueCards(scope: scope, asOf: asOf, limit: limit)
    }
}

public extension LibraryStudyResponses {
    func completeAudioSubmission(
        _ draft: StudyResponseDraft,
        submittedAt: Date = .now
    ) async throws -> StudyResponse {
        try await completeAudioSubmission(draft, submittedAt: submittedAt)
    }

    func studyResponses(
        matching query: StudyResponseQuery = StudyResponseQuery()
    ) async throws -> [StudyResponse] {
        try await studyResponses(matching: query)
    }

    func deleteStudyResponse(id: UUID, asOf: Date = .now) async throws -> Bool {
        try await deleteStudyResponse(id: id, asOf: asOf)
    }
}

public extension LibraryScheduling {
    func optimizeSchedulingIfNeeded(asOf: Date = .now) async throws -> FSRSOptimizationResult? {
        try await optimizeSchedulingIfNeeded(asOf: asOf)
    }
}

// MARK: - SQLite adapter

/// The sole production adapter that knows `ItemStore`. Presentation, API, and
/// synchronization code receive application capabilities instead of the store.
public actor SQLiteLibraryRepository: LibraryRepository, LibraryItemTypeEditingSafeguarding {
    let store: ItemStore

    public init(databaseURL: URL, profileID: String = "default") throws {
        store = try ItemStore(databaseURL: databaseURL, profileID: profileID)
    }

    /// Kept for migration and test composition. The wrapped store never escapes.
    public init(store: ItemStore) {
        self.store = store
    }

    public func bootstrap() async throws { try await store.bootstrap() }

    public func coldHomeSnapshot(
        scope: DeckScope,
        asOf: Date
    ) async throws -> ColdLibraryHomeSnapshot {
        try await store.coldLibraryHomeSnapshot(scope: scope, asOf: asOf)
    }

    public func mediaStore() async -> MediaStore? { await store.media }

    public func libraryID() async throws -> UUID { try await store.libraryID() }
    public func loadItemTypes() async throws -> ItemTypeLoadResult { try await store.loadItemTypes() }
    public func loadItemTypeCatalog() async throws -> ItemTypeCatalog {
        try await store.loadItemTypeCatalog()
    }
    public func effectiveItemTypePolicy(for deckID: UUID) async throws -> DeckItemTypePolicy? {
        try await store.effectiveItemTypePolicy(for: deckID)
    }
    public func items(
        scope: DeckScope,
        sort: ItemSortOrder,
        search: String
    ) async throws -> [SavedItemSummary] {
        try await store.listItems(scope: scope, sort: sort, search: search)
    }
    public func item(id: UUID) async throws -> (item: Item, itemType: ItemType)? {
        try await store.fetchItem(id: id)
    }
    public func itemBrowseSchedules(itemIDs: [UUID]) async throws -> [UUID: ItemBrowseSchedule] {
        try await store.fetchItemBrowseSchedules(itemIDs: itemIDs)
    }
    public func scopeSummary(scope: DeckScope, asOf: Date) async throws -> ScopeSummary {
        try await store.scopeSummary(scope: scope, asOf: asOf)
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
    public func deleteAllUnassignedItems(asOf: Date) async throws -> Int {
        try await store.deleteAllUnassignedItems(now: asOf)
    }
    public func moveItem(id: UUID, to deckID: UUID?) async throws -> Bool {
        try await store.updateItemDeck(itemID: id, deckID: deckID)
    }
    public func performBulkItemOperations(
        _ operations: [ItemBulkOperation],
        asOf: Date
    ) async throws -> [ItemBulkOperationResult] {
        try await store.executeItemBulk(operations, dryRun: false, now: asOf)
    }
    public func reserveMedia(
        data: Data,
        kind: MediaKind,
        altText: String,
        asOf: Date
    ) async throws -> ReservedMediaAsset {
        try await store.reserveMedia(data: data, kind: kind, altText: altText, now: asOf)
    }

    public func deck(id: UUID) async throws -> Deck { try await store.deck(id: id) }
    public func deckSummaries(asOf: Date) async throws -> [DeckSummary] {
        try await store.deckSummaries(asOf: asOf)
    }
    public func createDeck(_ deck: Deck) async throws -> Deck { try await store.createDeck(deck) }
    public func updateDeck(_ deck: Deck) async throws -> Deck { try await store.updateDeck(deck) }
    public func deleteDeck(id: UUID) async throws -> Bool { try await store.deleteDeck(id: id) }
    public func resetDeckProgress(id: UUID, asOf: Date) async throws -> Int {
        try await store.resetDeckProgress(id: id, now: asOf)
    }

    public func createItemType(_ itemType: ItemType) async throws -> ItemType {
        try await store.createItemType(itemType)
    }
    public func updateItemType(_ itemType: ItemType, asOf: Date) async throws -> ItemType {
        try await store.updateItemType(itemType, now: asOf)
    }
    public func duplicateItemType(id: UUID, name: String) async throws -> ItemType {
        try await store.duplicateItemType(id: id, name: name)
    }
    public func itemTypeEditingImpact(id: UUID) async throws -> ItemTypeEditingImpact {
        try await store.itemTypeEditingImpact(id: id)
    }
    public func unlockItemType(id: UUID) async throws -> ItemType {
        try await store.unlockItemType(id: id)
    }
    public func itemTypeSchemaChangeImpact(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeSchemaChangeImpact {
        try await store.itemTypeSchemaChangeImpact(from: existing, to: updated)
    }
    public func repairItemTypeDefinition(id: UUID, asOf: Date) async throws -> ItemType {
        try await store.repairItemTypeDefinition(id: id, now: asOf)
    }
    public func countItems(itemTypeID: UUID) async throws -> Int {
        try await store.countItems(itemTypeID: itemTypeID)
    }
    public func deleteItemType(id: UUID) async throws -> Bool {
        try await store.deleteItemType(id: id)
    }

    public func dueCount(scope: DeckScope, asOf: Date) async throws -> Int {
        try await store.dueCount(scope: scope, asOf: asOf)
    }
    public func dueCards(
        scope: DeckScope,
        asOf: Date,
        limit: Int?
    ) async throws -> [DueCard] {
        try await store.fetchDueCards(scope: scope, asOf: asOf, limit: limit)
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

    public func completeAudioSubmission(
        _ draft: StudyResponseDraft,
        submittedAt: Date
    ) async throws -> StudyResponse {
        try await store.completeAudioSubmission(draft, submittedAt: submittedAt)
    }

    public func studyResponses(matching query: StudyResponseQuery) async throws -> [StudyResponse] {
        try await store.studyResponses(matching: query)
    }

    public func studyResponse(id: UUID) async throws -> StudyResponse {
        try await store.studyResponse(id: id)
    }

    public func studyResponseMediaBytes(id: UUID) async throws -> (StudyResponse, MediaAsset, Data) {
        try await store.studyResponseMediaBytes(id: id)
    }

    public func deleteStudyResponse(id: UUID, asOf: Date) async throws -> Bool {
        try await store.deleteStudyResponse(id: id, asOf: asOf)
    }

    public func ordinaryMediaReferenceCount(hash: String) async throws -> Int {
        try await store.ordinaryMediaReferenceCount(hash: hash)
    }

    public func isStudyResponseMediaHash(_ hash: String) async throws -> Bool {
        try await store.isStudyResponseMediaHash(hash)
    }

    public func studyResponseCount(cardIDs: Set<UUID>) async throws -> Int {
        try await store.studyResponseCount(cardIDs: cardIDs)
    }

    public func studyResponseCount(itemIDs: Set<UUID>) async throws -> Int {
        try await store.studyResponseCount(itemIDs: itemIDs)
    }

    public func studyResponseCount(templateIDs: Set<UUID>) async throws -> Int {
        try await store.studyResponseCount(templateIDs: templateIDs)
    }
    public func revertReview(id: UUID, asOf: Date) async throws {
        try await store.revertReview(reviewLogID: id, now: asOf)
    }

    public func studyDayRolloverMinutes() async throws -> Int {
        try await store.studyDayRolloverMinutes()
    }
    public func setStudyDayRolloverMinutes(_ minutes: Int) async throws {
        try await store.setStudyDayRolloverMinutes(minutes)
    }
    public func optimizeSchedulingIfNeeded(asOf: Date) async throws -> FSRSOptimizationResult? {
        try await store.optimizeSchedulingIfNeeded(now: asOf)
    }

    public func importJSONItems(
        from data: Data,
        itemTypeID: UUID?,
        context: ImportContext,
        asOf: Date
    ) async throws -> [SavedItemSummary] {
        try await store.importItemSummaries(
            from: data,
            adapter: JSONImportAdapter(),
            itemTypeID: itemTypeID,
            context: context,
            now: asOf
        )
    }
    public func importCSVItems(
        from data: Data,
        itemTypeID: UUID?,
        itemTypeName: String,
        context: ImportContext,
        asOf: Date
    ) async throws -> [SavedItemSummary] {
        try await store.importItemSummaries(
            from: data,
            adapter: CSVImportAdapter(itemTypeName: itemTypeName),
            itemTypeID: itemTypeID,
            context: context,
            now: asOf
        )
    }

    public func importPortableDeck(
        from source: URL,
        conflictResolution: PortableDeckTypeConflictResolution
    ) async throws -> PortableDeckImportResult {
        try await PortableDeck.importDeck(
            from: source,
            into: store,
            conflictResolution: conflictResolution
        )
    }
    public func importAuthoredDeck(from source: URL) async throws -> PortableDeckImportResult {
        try await AuthoredDeck.importDeck(from: source, into: store)
    }
    public func importAuthoredItems(
        from source: URL,
        into deckID: UUID
    ) async throws -> PortableDeckImportResult {
        try await AuthoredDeck.importItems(from: source, into: store, deckID: deckID)
    }
    public func exportPortableDeck(id: UUID, to destination: URL) async throws {
        try await PortableDeck.export(deckID: id, from: store, to: destination)
    }

    public func currentChangeCursor() async throws -> Int64 {
        try await store.currentChangeCursor()
    }
    public func recordLibraryAlias(_ aliasID: UUID, canonicalID: UUID) async throws {
        try await store.recordLibraryAlias(aliasID, canonicalID: canonicalID)
    }
    public func libraryAliases(canonicalID: UUID) async throws -> Set<UUID> {
        try await store.libraryAliases(canonicalID: canonicalID)
    }
    public func changes(after cursor: Int64, limit: Int) async throws -> [LibraryChange] {
        try await store.libraryChanges(after: cursor, limit: limit)
    }
    public func createBackup(at destination: URL) async throws {
        try await store.createValidationDatabaseSnapshot(at: destination)
    }

    public func applySynchronizedCard(_ card: Card) async throws { try await store.applySynchronizedCard(card) }
    public func applySynchronizedReview(_ log: ReviewLog) async throws { try await store.applySynchronizedReview(log) }
    public func synchronizedReviewRecord(id: UUID) async throws -> SynchronizedReviewRecord {
        try await store.synchronizedReviewRecord(id: id)
    }
    public func synchronizedItemRecord(id: UUID) async throws -> SynchronizedItemRecord {
        try await store.synchronizedItemRecord(id: id)
    }
    public func reviewRevertRecord(id: UUID) async throws -> ReviewRevertRecord {
        try await store.reviewRevertRecord(id: id)
    }
    public func itemTypeMembershipRecord(id: String) async throws -> ItemTypeMembershipRecord {
        try await store.itemTypeMembershipRecord(id: id)
    }
    public func schedulingSettingsRecord(id: String) async throws -> SchedulingSettingsRecord {
        try await store.schedulingSettingsRecord(id: id)
    }
    public func portableItemTypeMappingRecord(id: String) async throws -> PortableItemTypeMappingRecord {
        try await store.portableItemTypeMappingRecord(id: id)
    }
    public func applySynchronizedBatch(_ mutations: [SynchronizedLibraryMutation]) async throws {
        for mutation in mutations {
            switch mutation {
            case let .itemType(type): try ItemTypeValidation.validate(type)
            case let .deck(deck):
                guard deck.newCardsPerDay.map({ $0 >= 0 }) ?? true else {
                    throw DatabaseError.invalidDeck("Daily new-card limit cannot be negative.")
                }
            default: break
            }
        }
        try await store.applySynchronizedBatch(mutations)
    }

    public func verifyBackup(at destination: URL) async throws {
        let verification = try SQLiteLibraryRepository(databaseURL: destination)
        try await verification.bootstrap()
        _ = try await verification.libraryID()
    }
}

extension SQLiteLibraryRepository: LibraryScenarioSeeding {
    public func corruptItemTypeDefinitionForTesting(id: UUID) async throws {
        try await store.testingCorruptItemTypeDefinition(id: id)
    }
}
