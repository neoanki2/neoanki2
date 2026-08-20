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
    func acknowledgeRepeatedLapses(itemIDs: Set<UUID>, asOf: Date) async throws -> Int
    func performBulkItemOperations(_ operations: [ItemBulkOperation], asOf: Date) async throws -> [ItemBulkOperationResult]
    func reserveMedia(data: Data, kind: MediaKind, altText: String, asOf: Date) async throws -> ReservedMediaAsset
}

public protocol LibraryDeckManaging: Sendable {
    func deck(id: UUID) async throws -> Deck
    func deckSummaries(asOf: Date) async throws -> [DeckSummary]
    func createDeck(_ deck: Deck) async throws -> Deck
    func updateDeck(_ deck: Deck) async throws -> Deck
    func moveDeck(id: UUID, to destination: DeckMoveDestination) async throws -> Bool
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

/// Atomic, transaction-bound persistence capability used only by Item Type
/// Studio. Kept separate from the historical editing-safeguard contract so
/// existing repository conformers remain source-compatible.
public protocol LibraryItemTypeStudioSaving: Sendable {
    func prepareItemTypeUpdateAuthorization(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeUpdateAuthorization
    func updateItemType(
        _ itemType: ItemType,
        authorization: ItemTypeUpdateAuthorization,
        asOf: Date
    ) async throws -> ItemType
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
    /// Computes all four outcomes against one instant without recording a review.
    func reviewSchedulePreviews(
        cardID: UUID,
        asOf: Date
    ) async throws -> [ReviewRating: ReviewSchedulePreview]
}

/// A presentation-safe projection of one possible review answer.
public struct ReviewSchedulePreview: Sendable, Equatable {
    public let rating: ReviewRating
    public let reviewedAt: Date
    public let memoryBefore: MemoryState
    public let memoryAfter: MemoryState
    public let predictedRetrievability: Double
    public let rawIntervalDays: Double
    public let operationalIntervalSeconds: Int
    public let presetID: UUID?
    public let parameterSetID: UUID?
    public let modelVersion: String
    public let timingPolicyVersion: String
    public let intervalPolicyVersion: String
    public let finalDueAt: Date
    public let constraintReason: String?

    public init(_ value: ReviewSchedulePreviewDetail, reviewedAt: Date) {
        rating = value.rating
        self.reviewedAt = reviewedAt
        memoryBefore = value.memoryBefore
        memoryAfter = value.memoryAfter
        predictedRetrievability = value.predictedRetrievability
        rawIntervalDays = value.rawIntervalDays
        operationalIntervalSeconds = value.operationalIntervalSeconds
        presetID = value.presetID
        parameterSetID = value.parameterSetID
        modelVersion = value.modelVersion
        timingPolicyVersion = value.timingPolicyVersion
        intervalPolicyVersion = value.intervalPolicyVersion
        finalDueAt = value.finalDueAt
        constraintReason = value.constraintReason
    }

    /// Compatibility initializer for lightweight repository doubles. Production
    /// repositories use the Core detailed-preview projection above.
    public init(rating: ReviewRating, reviewedAt: Date, memory: MemoryState) {
        self.rating = rating
        self.reviewedAt = reviewedAt
        memoryBefore = memory
        memoryAfter = memory
        predictedRetrievability = 1
        rawIntervalDays = max(0, memory.due.timeIntervalSince(reviewedAt) / 86_400)
        operationalIntervalSeconds = max(0, Int(ceil(memory.due.timeIntervalSince(reviewedAt))))
        presetID = nil
        parameterSetID = nil
        modelVersion = "unavailable"
        timingPolicyVersion = FSRSScheduler.elapsedPolicyIdentifier
        intervalPolicyVersion = "continuous-due-v1"
        finalDueAt = memory.due
        constraintReason = rating == .again ? "immediate-repair-v1" : nil
    }

    /// Backwards-compatible presentation alias.
    public var memory: MemoryState { memoryAfter }

    public var intervalSeconds: TimeInterval {
        TimeInterval(operationalIntervalSeconds)
    }
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
    func schedulingHealthSnapshot() async throws -> LibrarySchedulingHealth
    func restoreDefaultScheduling(now: Date) async throws -> LibrarySchedulingHealth
    func rollbackScheduling(to parameterSetID: UUID?, now: Date) async throws -> LibrarySchedulingHealth
    func fsrsParameterSetHistory() async throws -> [LibraryFSRSParameterSet]
    func fsrsOptimizationRunHistory(limit: Int?) async throws -> [LibraryFSRSOptimizationRun]
}

public enum SchedulingRecoveryError: LocalizedError, Sendable, Equatable {
    case unavailable

    public var errorDescription: String? {
        "No recoverable scheduling parameter version is available."
    }
}

public struct LibrarySchedulingHealth: Sendable, Equatable {
    public let modelIdentifier: String
    public let desiredRetention: Double
    public let maximumIntervalDays: Int
    public let automaticOptimizationEnabled: Bool
    public let parameterCount: Int
    public let usesPopulationDefaults: Bool
    public let activeParameterSetID: UUID?
    public let activeParameterSource: String?
    public let optimizerParityVerified: Bool
    public let lastOptimizationDecision: String?
    public let lastOptimizationReason: String?
    public let lastOptimizationCompletedAt: Date?
    public let migrationStatus: String?
    public let legacyParametersQuarantined: Bool
    public let canRestoreDefaults: Bool
    public let canRollback: Bool

    public var optimizerStatus: String {
        if !optimizerParityVerified { return "parityVerificationPending" }
        return lastOptimizationDecision ?? "notRun"
    }

    public init(
        modelIdentifier: String,
        desiredRetention: Double,
        maximumIntervalDays: Int,
        automaticOptimizationEnabled: Bool,
        parameterCount: Int,
        usesPopulationDefaults: Bool,
        activeParameterSetID: UUID? = nil,
        activeParameterSource: String? = nil,
        optimizerParityVerified: Bool = false,
        lastOptimizationDecision: String? = nil,
        lastOptimizationReason: String? = nil,
        lastOptimizationCompletedAt: Date? = nil,
        migrationStatus: String? = nil,
        legacyParametersQuarantined: Bool = false,
        canRestoreDefaults: Bool,
        canRollback: Bool
    ) {
        self.modelIdentifier = modelIdentifier
        self.desiredRetention = desiredRetention
        self.maximumIntervalDays = maximumIntervalDays
        self.automaticOptimizationEnabled = automaticOptimizationEnabled
        self.parameterCount = parameterCount
        self.usesPopulationDefaults = usesPopulationDefaults
        self.activeParameterSetID = activeParameterSetID
        self.activeParameterSource = activeParameterSource
        self.optimizerParityVerified = optimizerParityVerified
        self.lastOptimizationDecision = lastOptimizationDecision
        self.lastOptimizationReason = lastOptimizationReason
        self.lastOptimizationCompletedAt = lastOptimizationCompletedAt
        self.migrationStatus = migrationStatus
        self.legacyParametersQuarantined = legacyParametersQuarantined
        self.canRestoreDefaults = canRestoreDefaults
        self.canRollback = canRollback
    }
}

public struct LibraryFSRSParameterSet: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let isActive: Bool
    public let weights: [Double]
    public let modelVersion: String
    public let upstreamCommit: String
    public let sourceChecksum: String
    public let fixtureChecksum: String?
    public let scope: String
    public let source: String
    public let inputFingerprint: String?
    public let trainingCutoff: Date?
    public let metrics: [String: Double]
    public let previousParameterSetID: UUID?
    public let createdAt: Date

    public init(_ value: FSRSParameterSet, isActive: Bool = false) {
        id = value.id
        self.isActive = isActive
        weights = value.weights
        modelVersion = value.modelVersion
        upstreamCommit = value.upstreamCommit
        sourceChecksum = value.sourceChecksum
        fixtureChecksum = value.fixtureChecksum
        scope = value.scope
        source = value.source.rawValue
        inputFingerprint = value.inputFingerprint
        trainingCutoff = value.trainingCutoff
        metrics = value.metrics
        previousParameterSetID = value.previousParameterSetID
        createdAt = value.createdAt
    }
}

public struct LibraryFSRSOptimizationRun: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let presetID: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let trainingCutoff: Date
    public let inputFingerprint: String
    public let eligibleTargetCount: Int
    public let distinctCardCount: Int
    public let failureCount: Int
    public let studyDayCount: Int
    public let excludedCounts: [String: Int]
    public let foldCount: Int
    public let metrics: [String: Double]
    public let decision: String
    public let reason: String?
    public let candidateParameterSetID: UUID?

    public init(_ value: FSRSOptimizationRun) {
        id = value.id
        presetID = value.presetID
        startedAt = value.startedAt
        completedAt = value.completedAt
        trainingCutoff = value.trainingCutoff
        inputFingerprint = value.inputFingerprint
        eligibleTargetCount = value.eligibleTargetCount
        distinctCardCount = value.distinctCardCount
        failureCount = value.failureCount
        studyDayCount = value.studyDayCount
        excludedCounts = value.excludedCounts
        foldCount = value.foldCount
        metrics = value.metrics
        decision = value.decision.rawValue
        reason = value.reason
        candidateParameterSetID = value.candidateParameterSetID
    }
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

    func acknowledgeRepeatedLapses(
        itemIDs: Set<UUID>,
        asOf: Date = .now
    ) async throws -> Int {
        try await acknowledgeRepeatedLapses(itemIDs: itemIDs, asOf: asOf)
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

    func reviewSchedulePreviews(
        cardID: UUID,
        asOf: Date
    ) async throws -> [ReviewRating: ReviewSchedulePreview] {
        [:]
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

    func schedulingHealthSnapshot() async throws -> LibrarySchedulingHealth {
        LibrarySchedulingHealth(
            modelIdentifier: "Unavailable",
            desiredRetention: SchedulerPersistenceConstants.desiredRetention,
            maximumIntervalDays: SchedulerPersistenceConstants.maximumIntervalDays,
            automaticOptimizationEnabled: false,
            parameterCount: 0,
            usesPopulationDefaults: true,
            canRestoreDefaults: false,
            canRollback: false
        )
    }

    func restoreDefaultScheduling(now: Date = .now) async throws -> LibrarySchedulingHealth {
        throw SchedulingRecoveryError.unavailable
    }

    func rollbackScheduling(
        to parameterSetID: UUID? = nil,
        now: Date = .now
    ) async throws -> LibrarySchedulingHealth {
        throw SchedulingRecoveryError.unavailable
    }

    func fsrsParameterSetHistory() async throws -> [LibraryFSRSParameterSet] { [] }

    func fsrsOptimizationRunHistory(limit: Int? = nil) async throws -> [LibraryFSRSOptimizationRun] {
        []
    }
}

// MARK: - SQLite adapter

/// The sole production adapter that knows `ItemStore`. Presentation, API, and
/// synchronization code receive application capabilities instead of the store.
public actor SQLiteLibraryRepository:
    LibraryRepository,
    LibraryItemTypeEditingSafeguarding,
    LibraryItemTypeStudioSaving
{
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
    public func acknowledgeRepeatedLapses(
        itemIDs: Set<UUID>,
        asOf: Date
    ) async throws -> Int {
        try await store.acknowledgeRepeatedLapses(itemIDs: itemIDs, asOf: asOf)
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
    public func moveDeck(id: UUID, to destination: DeckMoveDestination) async throws -> Bool {
        try await store.moveDeck(id: id, to: destination)
    }
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
    public func updateItemType(
        _ itemType: ItemType,
        authorization: ItemTypeUpdateAuthorization,
        asOf: Date
    ) async throws -> ItemType {
        try await store.updateItemType(itemType, authorization: authorization, now: asOf)
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
    public func prepareItemTypeUpdateAuthorization(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeUpdateAuthorization {
        try await store.prepareItemTypeUpdateAuthorization(from: existing, to: updated)
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

    public func reviewSchedulePreviews(
        cardID: UUID,
        asOf: Date
    ) async throws -> [ReviewRating: ReviewSchedulePreview] {
        let details = try await store.reviewPreviewDetails(cardID: cardID, now: asOf)
        return Dictionary(uniqueKeysWithValues: details.map { rating, detail in
            (rating, ReviewSchedulePreview(detail, reviewedAt: asOf))
        })
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
    public func schedulingHealthSnapshot() async throws -> LibrarySchedulingHealth {
        let snapshot = try await store.schedulingHealthSnapshot()
        return LibrarySchedulingHealth(
            modelIdentifier: snapshot.activeModelVersion
                ?? SchedulerPersistenceConstants.memoryModelVersion,
            desiredRetention: snapshot.desiredRetention,
            maximumIntervalDays: snapshot.preset.maximumIntervalDays,
            automaticOptimizationEnabled: snapshot.automaticOptimizationEnabled,
            parameterCount: snapshot.activeParameterSet?.weights.count ?? 0,
            usesPopulationDefaults: snapshot.activeSource == .populationDefault,
            activeParameterSetID: snapshot.activeParameterSet?.id,
            activeParameterSource: snapshot.activeSource?.rawValue,
            optimizerParityVerified: snapshot.optimizerParityVerified,
            lastOptimizationDecision: snapshot.lastOptimizationRun?.decision.rawValue,
            lastOptimizationReason: snapshot.lastOptimizationRun?.reason,
            lastOptimizationCompletedAt: snapshot.lastOptimizationRun?.completedAt,
            migrationStatus: snapshot.latestMigration?.status.rawValue,
            legacyParametersQuarantined: snapshot.legacyParametersQuarantined,
            canRestoreDefaults: snapshot.activeSource != .populationDefault,
            canRollback: snapshot.rollbackAvailable
        )
    }
    public func restoreDefaultScheduling(now: Date) async throws -> LibrarySchedulingHealth {
        try await store.restoreDefaultScheduling(now: now)
        return try await schedulingHealthSnapshot()
    }
    public func rollbackScheduling(
        to parameterSetID: UUID?,
        now: Date
    ) async throws -> LibrarySchedulingHealth {
        let snapshot = try await store.schedulingHealthSnapshot()
        guard let target = parameterSetID ?? snapshot.rollbackParameterSetIDs.first else {
            throw SchedulingRecoveryError.unavailable
        }
        guard snapshot.rollbackParameterSetIDs.contains(target) else {
            throw SchedulingRecoveryError.unavailable
        }
        try await store.rollbackScheduling(to: target, now: now)
        return try await schedulingHealthSnapshot()
    }
    public func fsrsParameterSetHistory() async throws -> [LibraryFSRSParameterSet] {
        let snapshot = try await store.schedulingHealthSnapshot()
        let activeID = snapshot.activeParameterSet?.id
        return try await store.fsrsParameterSets().map {
            LibraryFSRSParameterSet($0, isActive: $0.id == activeID)
        }
    }
    public func fsrsOptimizationRunHistory(
        limit: Int?
    ) async throws -> [LibraryFSRSOptimizationRun] {
        try await store.fsrsOptimizationRuns(limit: limit).map(LibraryFSRSOptimizationRun.init)
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
