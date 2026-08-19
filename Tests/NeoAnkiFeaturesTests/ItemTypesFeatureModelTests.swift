import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

private struct ItemTypeStudioFeatureFixture {
    let root: URL
    let store: ItemStore
    let repository: SQLiteLibraryRepository
    let itemType: ItemType
    let item: Item
    let basicCardID: UUID
    let audioCardID: UUID
}

private actor DelayedItemTypeStudioRepository:
    LibraryBrowsing,
    LibraryItemTypeManaging,
    LibraryStudyResponses,
    LibraryItemTypeEditingSafeguarding,
    LibraryItemTypeStudioSaving
{
    private let base: SQLiteLibraryRepository
    private var delaysNextGuardedUpdate = true
    private var updateStarted = false
    private var updateStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var updateRelease: CheckedContinuation<Void, Never>?

    init(base: SQLiteLibraryRepository) {
        self.base = base
    }

    func waitUntilUpdateStarts() async {
        guard !updateStarted else { return }
        await withCheckedContinuation { updateStartWaiters.append($0) }
    }

    func releaseUpdate() {
        updateRelease?.resume()
        updateRelease = nil
    }

    func libraryID() async throws -> UUID { try await base.libraryID() }
    func loadItemTypes() async throws -> ItemTypeLoadResult { try await base.loadItemTypes() }
    func loadItemTypeCatalog() async throws -> ItemTypeCatalog {
        try await base.loadItemTypeCatalog()
    }
    func effectiveItemTypePolicy(for deckID: UUID) async throws -> DeckItemTypePolicy? {
        try await base.effectiveItemTypePolicy(for: deckID)
    }
    func items(
        scope: DeckScope,
        sort: ItemSortOrder,
        search: String
    ) async throws -> [SavedItemSummary] {
        try await base.items(scope: scope, sort: sort, search: search)
    }
    func item(id: UUID) async throws -> (item: Item, itemType: ItemType)? {
        try await base.item(id: id)
    }
    func itemBrowseSchedules(itemIDs: [UUID]) async throws -> [UUID: ItemBrowseSchedule] {
        try await base.itemBrowseSchedules(itemIDs: itemIDs)
    }
    func scopeSummary(scope: DeckScope, asOf: Date) async throws -> ScopeSummary {
        try await base.scopeSummary(scope: scope, asOf: asOf)
    }
    func itemRecordsPage(offset: Int, limit: Int) async throws -> [LibraryItemRecord] {
        try await base.itemRecordsPage(offset: offset, limit: limit)
    }

    func createItemType(_ itemType: ItemType) async throws -> ItemType {
        try await base.createItemType(itemType)
    }
    func updateItemType(_ itemType: ItemType, asOf: Date) async throws -> ItemType {
        try await base.updateItemType(itemType, asOf: asOf)
    }
    func updateItemType(
        _ itemType: ItemType,
        authorization: ItemTypeUpdateAuthorization,
        asOf: Date
    ) async throws -> ItemType {
        if delaysNextGuardedUpdate {
            delaysNextGuardedUpdate = false
            updateStarted = true
            let waiters = updateStartWaiters
            updateStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { updateRelease = $0 }
        }
        return try await base.updateItemType(
            itemType,
            authorization: authorization,
            asOf: asOf
        )
    }
    func duplicateItemType(id: UUID, name: String) async throws -> ItemType {
        try await base.duplicateItemType(id: id, name: name)
    }
    func repairItemTypeDefinition(id: UUID, asOf: Date) async throws -> ItemType {
        try await base.repairItemTypeDefinition(id: id, asOf: asOf)
    }
    func countItems(itemTypeID: UUID) async throws -> Int {
        try await base.countItems(itemTypeID: itemTypeID)
    }
    func deleteItemType(id: UUID) async throws -> Bool { try await base.deleteItemType(id: id) }

    func itemTypeEditingImpact(id: UUID) async throws -> ItemTypeEditingImpact {
        try await base.itemTypeEditingImpact(id: id)
    }
    func unlockItemType(id: UUID) async throws -> ItemType {
        try await base.unlockItemType(id: id)
    }
    func itemTypeSchemaChangeImpact(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeSchemaChangeImpact {
        try await base.itemTypeSchemaChangeImpact(from: existing, to: updated)
    }
    func prepareItemTypeUpdateAuthorization(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeUpdateAuthorization {
        try await base.prepareItemTypeUpdateAuthorization(from: existing, to: updated)
    }

    func completeAudioSubmission(
        _ draft: StudyResponseDraft,
        submittedAt: Date
    ) async throws -> StudyResponse {
        try await base.completeAudioSubmission(draft, submittedAt: submittedAt)
    }
    func studyResponses(matching query: StudyResponseQuery) async throws -> [StudyResponse] {
        try await base.studyResponses(matching: query)
    }
    func studyResponse(id: UUID) async throws -> StudyResponse {
        try await base.studyResponse(id: id)
    }
    func studyResponseMediaBytes(id: UUID) async throws -> (StudyResponse, MediaAsset, Data) {
        try await base.studyResponseMediaBytes(id: id)
    }
    func deleteStudyResponse(id: UUID, asOf: Date) async throws -> Bool {
        try await base.deleteStudyResponse(id: id, asOf: asOf)
    }
    func ordinaryMediaReferenceCount(hash: String) async throws -> Int {
        try await base.ordinaryMediaReferenceCount(hash: hash)
    }
    func isStudyResponseMediaHash(_ hash: String) async throws -> Bool {
        try await base.isStudyResponseMediaHash(hash)
    }
    func studyResponseCount(cardIDs: Set<UUID>) async throws -> Int {
        try await base.studyResponseCount(cardIDs: cardIDs)
    }
    func studyResponseCount(itemIDs: Set<UUID>) async throws -> Int {
        try await base.studyResponseCount(itemIDs: itemIDs)
    }
    func studyResponseCount(templateIDs: Set<UUID>) async throws -> Int {
        try await base.studyResponseCount(templateIDs: templateIDs)
    }
}

/// Models an older compatibility conformer that supports ordinary item-type
/// updates but has no guarded atomic-update capability of its own.
private actor CompatibilityItemTypeRepository: LibraryItemTypeManaging {
    func createItemType(_ itemType: ItemType) async throws -> ItemType { itemType }
    func updateItemType(_ itemType: ItemType, asOf: Date) async throws -> ItemType { itemType }
    func duplicateItemType(id: UUID, name: String) async throws -> ItemType {
        throw DatabaseError.itemTypeNotFound(id)
    }
    func repairItemTypeDefinition(id: UUID, asOf: Date) async throws -> ItemType {
        throw DatabaseError.itemTypeNotFound(id)
    }
    func countItems(itemTypeID: UUID) async throws -> Int { 0 }
    func deleteItemType(id: UUID) async throws -> Bool { false }
}

/// A source-compatibility fixture that deliberately implements the historical
/// aggregate without adopting Item Type Studio safeguards.
private actor LegacyLibraryRepositoryConformer:
    LibraryRepository,
    LibraryItemTypeEditingSafeguarding
{
    let base: SQLiteLibraryRepository

    init(base: SQLiteLibraryRepository) { self.base = base }

    func bootstrap() async throws { try await base.bootstrap() }
    func coldHomeSnapshot(scope: DeckScope, asOf: Date) async throws -> ColdLibraryHomeSnapshot {
        try await base.coldHomeSnapshot(scope: scope, asOf: asOf)
    }
    func mediaStore() async -> MediaStore? { await base.mediaStore() }
    func libraryID() async throws -> UUID { try await base.libraryID() }
    func loadItemTypes() async throws -> ItemTypeLoadResult { try await base.loadItemTypes() }
    func loadItemTypeCatalog() async throws -> ItemTypeCatalog { try await base.loadItemTypeCatalog() }
    func effectiveItemTypePolicy(for deckID: UUID) async throws -> DeckItemTypePolicy? {
        try await base.effectiveItemTypePolicy(for: deckID)
    }
    func items(scope: DeckScope, sort: ItemSortOrder, search: String) async throws -> [SavedItemSummary] {
        try await base.items(scope: scope, sort: sort, search: search)
    }
    func item(id: UUID) async throws -> (item: Item, itemType: ItemType)? {
        try await base.item(id: id)
    }
    func itemBrowseSchedules(itemIDs: [UUID]) async throws -> [UUID: ItemBrowseSchedule] {
        try await base.itemBrowseSchedules(itemIDs: itemIDs)
    }
    func scopeSummary(scope: DeckScope, asOf: Date) async throws -> ScopeSummary {
        try await base.scopeSummary(scope: scope, asOf: asOf)
    }
    func itemRecordsPage(offset: Int, limit: Int) async throws -> [LibraryItemRecord] {
        try await base.itemRecordsPage(offset: offset, limit: limit)
    }
    func createItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary {
        try await base.createItem(item, asOf: asOf)
    }
    func updateItem(_ item: Item, asOf: Date) async throws -> SavedItemSummary {
        try await base.updateItem(item, asOf: asOf)
    }
    func deleteItem(id: UUID, asOf: Date) async throws -> Bool {
        try await base.deleteItem(id: id, asOf: asOf)
    }
    func deleteAllUnassignedItems(asOf: Date) async throws -> Int {
        try await base.deleteAllUnassignedItems(asOf: asOf)
    }
    func moveItem(id: UUID, to deckID: UUID?) async throws -> Bool {
        try await base.moveItem(id: id, to: deckID)
    }
    func acknowledgeRepeatedLapses(itemIDs: Set<UUID>, asOf: Date) async throws -> Int {
        try await base.acknowledgeRepeatedLapses(itemIDs: itemIDs, asOf: asOf)
    }
    func performBulkItemOperations(
        _ operations: [ItemBulkOperation],
        asOf: Date
    ) async throws -> [ItemBulkOperationResult] {
        try await base.performBulkItemOperations(operations, asOf: asOf)
    }
    func reserveMedia(
        data: Data,
        kind: MediaKind,
        altText: String,
        asOf: Date
    ) async throws -> ReservedMediaAsset {
        try await base.reserveMedia(data: data, kind: kind, altText: altText, asOf: asOf)
    }
    func deck(id: UUID) async throws -> Deck { try await base.deck(id: id) }
    func deckSummaries(asOf: Date) async throws -> [DeckSummary] {
        try await base.deckSummaries(asOf: asOf)
    }
    func createDeck(_ deck: Deck) async throws -> Deck { try await base.createDeck(deck) }
    func updateDeck(_ deck: Deck) async throws -> Deck { try await base.updateDeck(deck) }
    func moveDeck(id: UUID, to destination: DeckMoveDestination) async throws -> Bool {
        try await base.moveDeck(id: id, to: destination)
    }
    func deleteDeck(id: UUID) async throws -> Bool { try await base.deleteDeck(id: id) }
    func resetDeckProgress(id: UUID, asOf: Date) async throws -> Int {
        try await base.resetDeckProgress(id: id, asOf: asOf)
    }
    func deckDeletionImpact(id: UUID, policy: DeckDeletionPolicy) async throws -> DeckDeletionImpact {
        try await base.deckDeletionImpact(id: id, policy: policy)
    }
    func commitDeckDeletion(id: UUID, policy: DeckDeletionPolicy, asOf: Date) async throws {
        try await base.commitDeckDeletion(id: id, policy: policy, asOf: asOf)
    }
    func deckResetImpact(id: UUID) async throws -> DeckResetImpact {
        try await base.deckResetImpact(id: id)
    }
    func createItemType(_ itemType: ItemType) async throws -> ItemType {
        try await base.createItemType(itemType)
    }
    func updateItemType(_ itemType: ItemType, asOf: Date) async throws -> ItemType {
        try await base.updateItemType(itemType, asOf: asOf)
    }
    func duplicateItemType(id: UUID, name: String) async throws -> ItemType {
        try await base.duplicateItemType(id: id, name: name)
    }
    func repairItemTypeDefinition(id: UUID, asOf: Date) async throws -> ItemType {
        try await base.repairItemTypeDefinition(id: id, asOf: asOf)
    }
    func countItems(itemTypeID: UUID) async throws -> Int {
        try await base.countItems(itemTypeID: itemTypeID)
    }
    func deleteItemType(id: UUID) async throws -> Bool { try await base.deleteItemType(id: id) }
    func itemTypeEditingImpact(id: UUID) async throws -> ItemTypeEditingImpact {
        try await base.itemTypeEditingImpact(id: id)
    }
    func unlockItemType(id: UUID) async throws -> ItemType {
        try await base.unlockItemType(id: id)
    }
    func itemTypeSchemaChangeImpact(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeSchemaChangeImpact {
        try await base.itemTypeSchemaChangeImpact(from: existing, to: updated)
    }
    /// Deliberately offers only the preparation half of the new Studio
    /// transaction. Without authorized commit it must not project as a complete
    /// `LibraryItemTypeStudioSaving` capability.
    func prepareItemTypeUpdateAuthorization(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeUpdateAuthorization {
        try await base.prepareItemTypeUpdateAuthorization(from: existing, to: updated)
    }
    func dueCount(scope: DeckScope, asOf: Date) async throws -> Int {
        try await base.dueCount(scope: scope, asOf: asOf)
    }
    func dueCards(scope: DeckScope, asOf: Date, limit: Int?) async throws -> [DueCard] {
        try await base.dueCards(scope: scope, asOf: asOf, limit: limit)
    }
    func submitReview(
        cardID: UUID,
        rating: ReviewRating,
        asOf: Date,
        durationMilliseconds: Int
    ) async throws -> ReviewSubmission {
        try await base.submitReview(
            cardID: cardID,
            rating: rating,
            asOf: asOf,
            durationMilliseconds: durationMilliseconds
        )
    }
    func revertReview(id: UUID, asOf: Date) async throws {
        try await base.revertReview(id: id, asOf: asOf)
    }
    func reviewSchedulePreviews(
        cardID: UUID,
        asOf: Date
    ) async throws -> [ReviewRating: ReviewSchedulePreview] {
        try await base.reviewSchedulePreviews(cardID: cardID, asOf: asOf)
    }
    func completeAudioSubmission(
        _ draft: StudyResponseDraft,
        submittedAt: Date
    ) async throws -> StudyResponse {
        try await base.completeAudioSubmission(draft, submittedAt: submittedAt)
    }
    func studyResponses(matching query: StudyResponseQuery) async throws -> [StudyResponse] {
        try await base.studyResponses(matching: query)
    }
    func studyResponse(id: UUID) async throws -> StudyResponse { try await base.studyResponse(id: id) }
    func studyResponseMediaBytes(id: UUID) async throws -> (StudyResponse, MediaAsset, Data) {
        try await base.studyResponseMediaBytes(id: id)
    }
    func deleteStudyResponse(id: UUID, asOf: Date) async throws -> Bool {
        try await base.deleteStudyResponse(id: id, asOf: asOf)
    }
    func ordinaryMediaReferenceCount(hash: String) async throws -> Int {
        try await base.ordinaryMediaReferenceCount(hash: hash)
    }
    func isStudyResponseMediaHash(_ hash: String) async throws -> Bool {
        try await base.isStudyResponseMediaHash(hash)
    }
    func studyResponseCount(cardIDs: Set<UUID>) async throws -> Int {
        try await base.studyResponseCount(cardIDs: cardIDs)
    }
    func studyResponseCount(itemIDs: Set<UUID>) async throws -> Int {
        try await base.studyResponseCount(itemIDs: itemIDs)
    }
    func studyResponseCount(templateIDs: Set<UUID>) async throws -> Int {
        try await base.studyResponseCount(templateIDs: templateIDs)
    }
    func studyDayRolloverMinutes() async throws -> Int { try await base.studyDayRolloverMinutes() }
    func setStudyDayRolloverMinutes(_ minutes: Int) async throws {
        try await base.setStudyDayRolloverMinutes(minutes)
    }
    func optimizeSchedulingIfNeeded(asOf: Date) async throws -> FSRSOptimizationResult? {
        try await base.optimizeSchedulingIfNeeded(asOf: asOf)
    }
    func schedulingHealthSnapshot() async throws -> LibrarySchedulingHealth {
        try await base.schedulingHealthSnapshot()
    }
    func restoreDefaultScheduling(now: Date) async throws -> LibrarySchedulingHealth {
        try await base.restoreDefaultScheduling(now: now)
    }
    func rollbackScheduling(to parameterSetID: UUID?, now: Date) async throws -> LibrarySchedulingHealth {
        try await base.rollbackScheduling(to: parameterSetID, now: now)
    }
    func fsrsParameterSetHistory() async throws -> [LibraryFSRSParameterSet] {
        try await base.fsrsParameterSetHistory()
    }
    func fsrsOptimizationRunHistory(limit: Int?) async throws -> [LibraryFSRSOptimizationRun] {
        try await base.fsrsOptimizationRunHistory(limit: limit)
    }
    func importJSONItems(
        from data: Data,
        itemTypeID: UUID?,
        context: ImportContext,
        asOf: Date
    ) async throws -> [SavedItemSummary] {
        try await base.importJSONItems(from: data, itemTypeID: itemTypeID, context: context, asOf: asOf)
    }
    func importCSVItems(
        from data: Data,
        itemTypeID: UUID?,
        itemTypeName: String,
        context: ImportContext,
        asOf: Date
    ) async throws -> [SavedItemSummary] {
        try await base.importCSVItems(
            from: data,
            itemTypeID: itemTypeID,
            itemTypeName: itemTypeName,
            context: context,
            asOf: asOf
        )
    }
    func importPortableDeck(
        from source: URL,
        conflictResolution: PortableDeckTypeConflictResolution
    ) async throws -> PortableDeckImportResult {
        try await base.importPortableDeck(from: source, conflictResolution: conflictResolution)
    }
    func importAuthoredDeck(from source: URL) async throws -> PortableDeckImportResult {
        try await base.importAuthoredDeck(from: source)
    }
    func importAuthoredItems(from source: URL, into deckID: UUID) async throws -> PortableDeckImportResult {
        try await base.importAuthoredItems(from: source, into: deckID)
    }
    func exportPortableDeck(id: UUID, to destination: URL) async throws {
        try await base.exportPortableDeck(id: id, to: destination)
    }
    func currentChangeCursor() async throws -> Int64 { try await base.currentChangeCursor() }
    func changes(after cursor: Int64, limit: Int) async throws -> [LibraryChange] {
        try await base.changes(after: cursor, limit: limit)
    }
    func createBackup(at destination: URL) async throws { try await base.createBackup(at: destination) }
    func verifyBackup(at destination: URL) async throws { try await base.verifyBackup(at: destination) }
}

private func makeItemTypeStudioFeatureFixture() async throws -> ItemTypeStudioFeatureFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-item-type-studio-feature-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    let repository = SQLiteLibraryRepository(store: store)

    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let back = FieldDef(name: "Back", type: .text, isRequired: true)
    let notes = FieldDef(name: "Notes", type: .text, isRequired: false)
    let basic = Template(
        name: "Basic",
        layout: .focus,
        components: [
            TemplateComponent(
                region: .primary,
                purpose: .question,
                source: .field(front.id)
            ),
            TemplateComponent(
                region: .secondary,
                purpose: .expectedAnswer,
                source: .field(back.id),
                presentation: Presentation(reveal: .hiddenUntilAnswer)
            ),
        ],
        interaction: .reveal,
        skill: Skill(input: .text, output: .text, operation: .recognize)
    )
    let audio = Template(
        name: "Audio Submission",
        layout: .actionStage,
        components: [
            TemplateComponent(
                region: .primary,
                purpose: .question,
                source: .field(front.id)
            ),
        ],
        interaction: .audioSubmission,
        skill: Skill(input: .text, output: .audio, operation: .reproduce)
    )
    let itemType = ItemType(
        name: "Studio Fixture",
        fields: [front, back, notes],
        templates: [basic, audio]
    )
    _ = try await repository.createItemType(itemType)
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: front.id, value: .text("Question")),
            FieldValue(fieldID: back.id, value: .text("Answer")),
            FieldValue(fieldID: notes.id, value: .text("Populated note")),
        ]
    )
    _ = try await repository.createItem(item)
    let cards = try await repository.dueCards(scope: .allDecks, asOf: .now)
    let basicCardID = try #require(cards.first { $0.template.id == basic.id }?.id)
    let audioCardID = try #require(cards.first { $0.template.id == audio.id }?.id)
    let responseDraftURL = root.appendingPathComponent("response.m4a")
    try Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8)).write(to: responseDraftURL)
    _ = try await repository.completeAudioSubmission(StudyResponseDraft(
        cardID: audioCardID,
        fileURL: responseDraftURL,
        durationMilliseconds: 1_000,
        capturedAt: .now
    ))
    return ItemTypeStudioFeatureFixture(
        root: root,
        store: store,
        repository: repository,
        itemType: itemType,
        item: item,
        basicCardID: basicCardID,
        audioCardID: audioCardID
    )
}

@Test @MainActor func itemTypesFeatureCreatesOneCompleteItemTypeAndReloadsSelection() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-item-type-studio-create-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await repository.bootstrap()
    let model = ItemTypesFeatureModel(library: repository)
    await model.load()

    let itemTypeID = UUID()
    model.beginCreatingItemType(id: itemTypeID)
    var draft = try #require(model.studioDraft)
    draft.name = "Languages"
    model.studioDraft = draft

    let preparation = try await model.prepareSave()
    #expect(preparation.createsItemType)
    #expect(preparation.impact == .none)
    #expect(preparation.candidate.id == itemTypeID)
    #expect(preparation.candidate.fields.map(\.name) == ["Front", "Back"])
    #expect(preparation.candidate.templates.count == 1)

    let saved = try await model.commitSave(preparation)
    #expect(saved == preparation.candidate)
    #expect(model.selectedItemTypeID == itemTypeID)
    #expect(model.selectedItemType == saved)
    #expect(model.studioDraft?.isDirty == false)
    #expect(try await repository.loadItemTypeCatalog().itemTypes.contains(saved))
}

@Test @MainActor func itemTypesFeaturePersistsFieldReorderingWithoutChangingCardSetups() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())

    var draft = try #require(model.studioDraft)
    let originalFieldIDs = draft.fields.map(\.id)
    let movedField = draft.fields.remove(at: 2)
    draft.fields.insert(movedField, at: 0)
    let expectedFieldIDs = [movedField.id, originalFieldIDs[0], originalFieldIDs[1]]
    model.studioDraft = draft

    let preparation = try await model.prepareSave()
    #expect(preparation.candidate.fields.map(\.id) == expectedFieldIDs)
    let saved = try await model.commitSave(preparation)
    #expect(saved.fields.map(\.id) == expectedFieldIDs)

    let persisted = try #require(
        try await fixture.repository.loadItemTypeCatalog().itemTypes.first {
            $0.id == fixture.itemType.id
        }
    )
    #expect(persisted.fields.map(\.id) == expectedFieldIDs)
    #expect(persisted.templates.map(\.id) == fixture.itemType.templates.map(\.id))
    for originalSetup in fixture.itemType.templates {
        let persistedSetup = try #require(
            persisted.templates.first { $0.id == originalSetup.id }
        )
        #expect(persistedSetup.components.map(\.id) == originalSetup.components.map(\.id))
        #expect(persistedSetup.components == originalSetup.components)
        #expect(persistedSetup.layout == originalSetup.layout)
        #expect(persistedSetup.skill == originalSetup.skill)
    }
}

@Test @MainActor func prepareSaveAggregatesFieldSetupCardAndSpokenResponseImpact() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())

    var draft = try #require(model.studioDraft)
    let notesID = try #require(fixture.itemType.field(named: "Notes")?.id)
    let audioID = try #require(fixture.itemType.templates.first { $0.interaction == .audioSubmission }?.id)
    _ = draft.removeField(id: notesID)
    let removedAudioSetup = draft.removeCardSetup(id: audioID)
    #expect(removedAudioSetup)
    model.studioDraft = draft

    let preparation = try await model.prepareSave()
    #expect(preparation.impact.removedFields.map(\.id) == [notesID])
    #expect(preparation.impact.schemaChange.affectedItemCount == 1)
    #expect(preparation.impact.schemaChange.removedPopulatedFields == ["Notes"])
    #expect(preparation.impact.removedCardSetups.map(\.id) == [audioID])
    #expect(preparation.impact.retiresGeneratedCards)
    #expect(preparation.impact.generatedCardRetirementCount == 1)
    #expect(preparation.impact.persistentSpokenResponseCount == 1)
    #expect(preparation.impact.requiresConfirmation)

    let survivingCardBefore = try await fixture.store.card(id: fixture.basicCardID)
    let saved = try await model.commitSave(preparation)
    #expect(saved.templates.map(\.id) == fixture.itemType.templates.prefix(1).map(\.id))
    #expect(try await fixture.store.card(id: fixture.basicCardID) == survivingCardBefore)
    await #expect(throws: DatabaseError.self) {
        _ = try await fixture.store.card(id: fixture.audioCardID)
    }
    #expect(try await fixture.repository.studyResponseCount(templateIDs: [audioID]) == 0)
}

@Test @MainActor func retainedAvailabilityRetirementRequiresConfirmationWithoutResponses() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())

    let backID = try #require(fixture.itemType.field(named: "Back")?.id)
    let basicID = try #require(
        fixture.itemType.templates.first { $0.interaction == .reveal }?.id
    )
    let setupIndex = try #require(model.studioDraft?.cardSetups.firstIndex { $0.id == basicID })
    model.studioDraft?.cardSetups[setupIndex].availability = .fieldAbsent(backID)

    let preparation = try await model.prepareSave()
    #expect(preparation.impact.removedCardSetups.isEmpty)
    #expect(preparation.impact.generatedCardRetirementCount == 1)
    #expect(preparation.impact.persistentSpokenResponseCount == 0)
    #expect(preparation.impact.retiresGeneratedCards)
    #expect(preparation.impact.isDestructive)
    #expect(preparation.impact.requiresConfirmation)
}

@Test @MainActor func retainedClozeInteractionRetirementRequiresConfirmationWithoutResponses() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-item-type-studio-cloze-impact-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await repository.bootstrap()
    let cloze = BuiltInItemTypes.cloze.duplicated(name: "Cloze impact")
    _ = try await repository.createItemType(cloze)
    let textID = try #require(cloze.field(named: "Text")?.id)
    _ = try await repository.createItem(Item(itemTypeID: cloze.id, fields: [
        FieldValue(
            fieldID: textID,
            value: .cloze(
                "alpha beta",
                blanks: [
                    ClozeSpan(group: 1, start: 0, length: 5),
                    ClozeSpan(group: 2, start: 6, length: 4),
                ]
            )
        ),
    ]))

    let model = ItemTypesFeatureModel(library: repository)
    await model.load()
    model.selectItemType(id: cloze.id)
    #expect(model.beginEditingSelectedItemType())
    model.studioDraft?.cardSetups[0].interaction = .reveal

    let preparation = try await model.prepareSave()
    #expect(preparation.impact.removedCardSetups.isEmpty)
    #expect(preparation.impact.generatedCardRetirementCount == 2)
    #expect(preparation.impact.persistentSpokenResponseCount == 0)
    #expect(preparation.impact.requiresConfirmation)
}

@Test func compatibilityItemTypeManagerKeepsHistoricalRequirementSet() async throws {
    let repository: any LibraryItemTypeManaging = CompatibilityItemTypeRepository()
    let itemType = ItemType(name: "Compatibility", fields: [], templates: [])

    #expect(try await repository.updateItemType(itemType) == itemType)
}

@Test @MainActor func prepareSaveRejectsInvalidAndStaleDraftsWithoutMutation() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())

    var draft = try #require(model.studioDraft)
    draft.cardSetups.removeAll()
    model.studioDraft = draft
    await #expect(throws: ItemTypesFeatureError.finalCardSetupRequired) {
        _ = try await model.prepareSave()
    }

    model.studioDraft = ItemTypeStudioDraft(itemType: fixture.itemType)
    let preparation = try await model.prepareSave()
    model.studioDraft?.name = "Changed after confirmation"
    await #expect(throws: ItemTypesFeatureError.staleSavePreparation) {
        _ = try await model.commitSave(preparation)
    }
    let persisted = try #require(
        try await fixture.repository.loadItemTypeCatalog().itemTypes.first { $0.id == fixture.itemType.id }
    )
    #expect(persisted == fixture.itemType)
}

@Test @MainActor func itemTypesFeatureReportsTypeChangesAndProtectsDeletionWithItems() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())

    var draft = try #require(model.studioDraft)
    let notesID = try #require(fixture.itemType.field(named: "Notes")?.id)
    _ = draft.changeFieldType(id: notesID, to: .number)
    model.studioDraft = draft
    let preparation = try await model.prepareSave()
    let previousNotes = try #require(fixture.itemType.field(notesID))
    let updatedNotes = try #require(preparation.candidate.field(notesID))
    #expect(preparation.impact.changedFields == [ItemTypeStudioFieldUpdate(
        previous: previousNotes,
        updated: updatedNotes
    )])
    #expect(preparation.impact.schemaChange.typeChangedPopulatedFields == ["Notes"])
    #expect(try await model.selectedItemTypeDeletionImpact() == 1)
    await #expect(throws: ItemTypesFeatureError.itemTypeHasItems(1)) {
        try await model.deleteSelectedItemType()
    }

    _ = try await fixture.repository.deleteItem(id: fixture.item.id)
    try await model.deleteSelectedItemType()
    #expect(model.itemTypes.contains { $0.id == fixture.itemType.id } == false)
}

@Test @MainActor func commitSavePreservesNewerDraftEditsMadeWhilePersistenceAwaits() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let delayed = DelayedItemTypeStudioRepository(base: fixture.repository)
    let model = ItemTypesFeatureModel(library: delayed)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    model.studioDraft?.name = "Committed name"
    let preparation = try await model.prepareSave()

    let commit = Task { @MainActor in
        try await model.commitSave(preparation)
    }
    await delayed.waitUntilUpdateStarts()
    model.studioDraft?.name = "Newer unsaved name"
    await delayed.releaseUpdate()
    let saved = try await commit.value

    #expect(saved.name == "Committed name")
    #expect(model.studioDraft?.name == "Newer unsaved name")
    #expect(model.studioDraft?.isDirty == true)
    #expect(model.studioDraft?.originalSnapshot == saved)
    #expect(try await fixture.store.itemType(id: fixture.itemType.id).name == "Committed name")

    let newerPreparation = try await model.prepareSave()
    let newerSaved = try await model.commitSave(newerPreparation)
    #expect(newerSaved.name == "Newer unsaved name")
    #expect(model.studioDraft?.isDirty == false)
}

@Test @MainActor func rebasedSaveDoesNotResurrectCommittedPlaybackStash() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backID = try #require(fixture.itemType.field(named: "Back")?.id)
    var playable = fixture.itemType
    let backIndex = try #require(playable.fields.firstIndex { $0.id == backID })
    playable.fields[backIndex].type = .audio
    let basicIndex = try #require(playable.templates.firstIndex { $0.interaction == .reveal })
    let answerIndex = try #require(playable.templates[basicIndex].components.firstIndex {
        $0.source == .field(backID)
    })
    playable.templates[basicIndex].components[answerIndex].presentation.media = .autoplay
    _ = try await fixture.repository.updateItemType(playable)

    let delayed = DelayedItemTypeStudioRepository(base: fixture.repository)
    let model = ItemTypesFeatureModel(library: delayed)
    await model.load()
    model.selectItemType(id: playable.id)
    #expect(model.beginEditingSelectedItemType())
    _ = model.studioDraft?.changeFieldType(id: backID, to: .text)
    let preparation = try await model.prepareSave()

    let commit = Task { @MainActor in
        try await model.commitSave(preparation)
    }
    await delayed.waitUntilUpdateStarts()
    model.studioDraft?.name = "Unrelated newer name"
    await delayed.releaseUpdate()
    let saved = try await commit.value

    #expect(model.studioDraft?.name == "Unrelated newer name")
    #expect(model.studioDraft?.originalSnapshot == saved)
    _ = model.studioDraft?.changeFieldType(id: backID, to: .video)
    let rebasedComponent = try #require(
        model.studioDraft?.cardSetups
            .first { $0.id == playable.templates[basicIndex].id }?
            .components.first { $0.id == playable.templates[basicIndex].components[answerIndex].id }
    )
    #expect(rebasedComponent.mediaBehavior == .default)
}

@Test @MainActor func rebasedSaveDoesNotRestoreAnswersRemovedByCommittedAudioConversion() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let delayed = DelayedItemTypeStudioRepository(base: fixture.repository)
    let model = ItemTypesFeatureModel(library: delayed)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    let setupID = try #require(
        model.studioDraft?.cardSetups.first { $0.interaction == .reveal }?.id
    )
    let answerID = try #require(
        model.studioDraft?.cardSetups.first { $0.id == setupID }?
            .components.first { $0.purpose == .expectedAnswer }?.id
    )
    let setupIndex = try #require(
        model.studioDraft?.cardSetups.firstIndex { $0.id == setupID }
    )
    let enteredAudio = model.studioDraft?.cardSetups[setupIndex].setInteraction(
        .audioSubmission,
        confirmAudioAnswerRemoval: true
    )
    #expect(enteredAudio == true)
    let preparation = try await model.prepareSave()

    let commit = Task { @MainActor in
        try await model.commitSave(preparation)
    }
    await delayed.waitUntilUpdateStarts()
    model.studioDraft?.name = "Unrelated newer name"
    await delayed.releaseUpdate()
    _ = try await commit.value

    let leftAudioAfterSave = model.studioDraft?.cardSetups[setupIndex].setInteraction(.reveal)
    #expect(leftAudioAfterSave == true)
    #expect(model.studioDraft?.cardSetups[setupIndex].components.contains {
        $0.id == answerID
    } == false)
}

@Test @MainActor func rebasedSavePreservesAnswerStashCreatedByNewerInFlightConversion() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let delayed = DelayedItemTypeStudioRepository(base: fixture.repository)
    let model = ItemTypesFeatureModel(library: delayed)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    model.studioDraft?.name = "Committed rename"
    let setupID = try #require(
        model.studioDraft?.cardSetups.first { $0.interaction == .reveal }?.id
    )
    let answerID = try #require(
        model.studioDraft?.cardSetups.first { $0.id == setupID }?
            .components.first { $0.purpose == .expectedAnswer }?.id
    )
    let setupIndex = try #require(
        model.studioDraft?.cardSetups.firstIndex { $0.id == setupID }
    )
    let preparation = try await model.prepareSave()

    let commit = Task { @MainActor in
        try await model.commitSave(preparation)
    }
    await delayed.waitUntilUpdateStarts()
    let enteredAudio = model.studioDraft?.cardSetups[setupIndex].setInteraction(
        .audioSubmission,
        confirmAudioAnswerRemoval: true
    )
    #expect(enteredAudio == true)
    await delayed.releaseUpdate()
    _ = try await commit.value

    let restoredNewerAnswer = model.studioDraft?.cardSetups[setupIndex].setInteraction(.reveal)
    #expect(restoredNewerAnswer == true)
    #expect(model.studioDraft?.cardSetups[setupIndex].components.contains {
        $0.id == answerID
    } == true)
}

@Test @MainActor func commitSaveRejectsChangedPrivateResponseImpactWithoutDeletingDefinition() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    let audioID = try #require(
        fixture.itemType.templates.first { $0.interaction == .audioSubmission }?.id
    )
    let didRemove = model.studioDraft?.removeCardSetup(id: audioID)
    #expect(didRemove == true)
    let preparation = try await model.prepareSave()
    #expect(preparation.impact.persistentSpokenResponseCount == 1)
    let responseID = try #require(
        try await fixture.repository.studyResponses().first?.id
    )
    #expect(try await fixture.repository.deleteStudyResponse(id: responseID))

    await #expect(throws: ItemTypeUpdateError.studyResponseImpactChanged(expected: 1, actual: 0)) {
        try await model.commitSave(preparation)
    }
    let persisted = try #require(
        try await fixture.repository.loadItemTypeCatalog().itemTypes.first {
            $0.id == fixture.itemType.id
        }
    )
    #expect(persisted == fixture.itemType)
    #expect(try await fixture.store.card(id: fixture.audioCardID).templateID == audioID)
}

@Test @MainActor func commitSaveRejectsEqualCountReplacementOfAuthorizedPrivateResponse() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    let audioID = try #require(
        fixture.itemType.templates.first { $0.interaction == .audioSubmission }?.id
    )
    let replacementItem = Item(
        itemTypeID: fixture.itemType.id,
        fields: fixture.item.fields
    )
    _ = try await fixture.repository.createItem(replacementItem)
    let replacementCardID = try #require(
        try await fixture.store.cards().first {
            $0.itemID == replacementItem.id && $0.templateID == audioID
        }?.id
    )
    #expect(model.studioDraft?.removeCardSetup(id: audioID) == true)
    let preparation = try await model.prepareSave()
    #expect(preparation.impact.generatedCardRetirementCount == 2)
    #expect(preparation.impact.persistentSpokenResponseCount == 1)

    let originalResponseID = try #require(
        try await fixture.repository.studyResponses().first?.id
    )
    #expect(try await fixture.repository.deleteStudyResponse(id: originalResponseID))
    let replacementURL = fixture.root.appendingPathComponent("replacement-response.m4a")
    try Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8)).write(to: replacementURL)
    let replacement = try await fixture.repository.completeAudioSubmission(StudyResponseDraft(
        cardID: replacementCardID,
        fileURL: replacementURL,
        durationMilliseconds: 1_000,
        capturedAt: .now
    ))
    #expect(replacement.id != originalResponseID)
    #expect(try await fixture.repository.studyResponseCount(templateIDs: [audioID]) == 1)

    await #expect(throws: ItemTypeUpdateError.studyResponseImpactChanged(expected: 1, actual: 1)) {
        try await model.commitSave(preparation)
    }
    let persisted = try #require(
        try await fixture.repository.loadItemTypeCatalog().itemTypes.first {
            $0.id == fixture.itemType.id
        }
    )
    #expect(persisted == fixture.itemType)
    #expect(try await fixture.repository.studyResponse(id: replacement.id) == replacement)
    #expect(try await fixture.store.card(id: fixture.audioCardID).templateID == audioID)
}

@Test @MainActor func commitSaveRejectsExternalDefinitionChangeWithoutOverwrite() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    model.studioDraft?.name = "Studio edit"
    let preparation = try await model.prepareSave()

    var external = fixture.itemType
    external.name = "External edit"
    _ = try await fixture.repository.updateItemType(external)

    await #expect(throws: ItemTypeUpdateError.staleDefinition(fixture.itemType.id)) {
        try await model.commitSave(preparation)
    }
    let persisted = try #require(
        try await fixture.repository.loadItemTypeCatalog().itemTypes.first {
            $0.id == fixture.itemType.id
        }
    )
    #expect(persisted == external)
}

@Test @MainActor func staleNoOpSaveReloadsExternalDefinitionWithoutWriting() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    let preparation = try await model.prepareSave()

    var external = fixture.itemType
    external.name = "External no-op race"
    _ = try await fixture.repository.updateItemType(external)
    let baseline = try await fixture.store.currentChangeCursor()

    await #expect(throws: ItemTypeUpdateError.staleDefinition(fixture.itemType.id)) {
        try await model.commitSave(preparation)
    }
    #expect(model.selectedItemType == external)
    #expect(model.studioDraft?.originalSnapshot == external)
    #expect(model.studioDraft?.isDirty == false)
    #expect(try await fixture.store.currentChangeCursor() == baseline)
}

@Test @MainActor func commitSaveRejectsEmptyToPopulatedSchemaImpactAfterPreparation() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let notesID = try #require(fixture.itemType.field(named: "Notes")?.id)
    var emptyItem = fixture.item
    emptyItem.fields = emptyItem.fields.map { field in
        field.fieldID == notesID ? FieldValue(fieldID: notesID, value: .empty) : field
    }
    _ = try await fixture.repository.updateItem(emptyItem)

    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    _ = model.studioDraft?.removeField(id: notesID)
    let preparation = try await model.prepareSave()
    #expect(preparation.impact.schemaChange.affectedItemCount == 0)

    var populatedItem = emptyItem
    populatedItem.fields = populatedItem.fields.map { field in
        field.fieldID == notesID
            ? FieldValue(fieldID: notesID, value: .text("Concurrent value"))
            : field
    }
    _ = try await fixture.repository.updateItem(populatedItem)

    await #expect(throws: ItemTypeUpdateError.schemaImpactChanged(expected: 0, actual: 1)) {
        try await model.commitSave(preparation)
    }
    #expect(try await fixture.store.itemType(id: fixture.itemType.id) == fixture.itemType)
}

@Test @MainActor func existingNoOpSaveReloadsWithoutWritingChangeEvents() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ItemTypesFeatureModel(library: fixture.repository)
    await model.load()
    model.selectItemType(id: fixture.itemType.id)
    #expect(model.beginEditingSelectedItemType())
    let preparation = try await model.prepareSave()
    let baseline = try await fixture.store.currentChangeCursor()

    let saved = try await model.commitSave(preparation)

    #expect(saved == fixture.itemType)
    #expect(model.studioDraft?.isDirty == false)
    #expect(try await fixture.store.currentChangeCursor() == baseline)
    #expect(try await fixture.store.libraryChanges(after: baseline).isEmpty)
}

@Test @MainActor func itemTypesFeatureKeepsDeckProvidedTypesReadOnlyUntilUnlock() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-item-type-studio-included-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("Included.neoanki", isDirectory: true)
    let itemsDirectory = bundle.appendingPathComponent("items", isDirectory: true)
    try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "".write(to: itemsDirectory.appendingPathComponent("items.jsonl"), atomically: true, encoding: .utf8)
    try """
    {"kind":"neoanki","version":3,"root":"root","parts":["items/items.jsonl"]}
    {"kind":"type","id":"Study","name":"Included Study","fields":[{"id":"front","name":"Front","type":"text","required":true},{"id":"back","name":"Back","type":"text","required":true}],"templates":[{"name":"Card","prompt":[{"field":"front"}],"answer":[{"field":"back"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}
    {"kind":"deck","id":"root","name":"Included","itemTypes":["Study"],"defaultType":"Study"}
    """.write(to: bundle.appendingPathComponent("deck.jsonl"), atomically: true, encoding: .utf8)

    let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await repository.bootstrap()
    _ = try await repository.importAuthoredDeck(from: bundle)
    let model = ItemTypesFeatureModel(library: repository)
    await model.load()
    let included = try #require(model.includedItemTypeGroups.first?.itemTypes.first)
    model.selectItemType(id: included.id)
    #expect(model.isSelectedItemTypeReadOnly)
    #expect(model.beginEditingSelectedItemType())
    await #expect(throws: ItemTypesFeatureError.readOnlyItemType) {
        _ = try await model.prepareSave()
    }

    let impact = try await model.editingImpactForSelectedIncludedItemType()
    #expect(impact == .init(itemCount: 0, deckCount: 0, unassignedItemCount: 0))
    let exactImpact = try await model.editingImpactForIncludedItemType(id: included.id)
    #expect(exactImpact == impact)
    let duplicate = try await model.duplicateSelectedIncludedItemType(name: "Editable Study")
    #expect(duplicate.id != included.id)
    #expect(model.selectedItemTypeID == duplicate.id)
    #expect(model.isSelectedItemTypeReadOnly == false)

    await #expect(throws: ItemTypesFeatureError.includedItemTypeRequired) {
        _ = try await model.unlockItemType(id: duplicate.id)
    }
    // The navigator selection changed after impact preparation. Exact-ID
    // execution must still unlock the originally confirmed definition.
    let unlocked = try await model.unlockItemType(id: included.id)
    #expect(unlocked.id == included.id)
    #expect(model.selectedItemTypeID == included.id)
    #expect(model.isSelectedItemTypeReadOnly == false)
}

@Test @MainActor func legacyLibraryFeatureItemTypeMethodsRemainForwardingCompatible() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-library-feature-item-type-compat-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    let model = LibraryFeatureModel(library: repository)
    await model.bootstrap(startSync: false)

    var created = ItemTypeStudioDraft.new(id: UUID())
    created.name = "Compatibility Type"
    let original = try created.candidateItemType()
    try await model.createItemType(original)
    #expect(model.itemTypes.contains { $0.id == original.id })

    var updated = original
    updated.name = "Compatibility Type Updated"
    try await model.updateItemType(updated)
    #expect(model.itemTypes.first { $0.id == original.id }?.name == updated.name)

    try await model.duplicateItemType(id: original.id, name: "Compatibility Copy")
    let duplicate = try #require(model.itemTypes.first { $0.name == "Compatibility Copy" })
    #expect(duplicate.id != original.id)
    try await model.deleteItemType(id: duplicate.id)
    #expect(model.itemTypes.contains { $0.id == duplicate.id } == false)

    try await model.repairItemType(id: original.id)
    let repaired = try #require(model.itemTypes.first { $0.id == original.id })
    #expect(repaired.name == updated.name)
    #expect(repaired.fields.map(\.name) == ["Front", "Back"])
}

@Test @MainActor func legacyLibraryFeatureResponseCountForwardsByTemplateIdentity() async throws {
    let fixture = try await makeItemTypeStudioFeatureFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = LibraryFeatureModel(library: fixture.repository)
    let audioID = try #require(
        fixture.itemType.templates.first { $0.interaction == .audioSubmission }?.id
    )

    #expect(try await model.studyResponseCount(templateIDs: [audioID]) == 1)
    #expect(try await model.studyResponseCount(templateIDs: [UUID()]) == 0)
}

@Test @MainActor func legacyLibraryFeatureSafeguardMethodsRemainForwardingCompatible() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-library-feature-safeguard-compat-\(UUID().uuidString)", isDirectory: true)
    let bundle = directory.appendingPathComponent("Deck.neoanki", isDirectory: true)
    let itemsDirectory = bundle.appendingPathComponent("items", isDirectory: true)
    try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "".write(
        to: itemsDirectory.appendingPathComponent("items.jsonl"),
        atomically: true,
        encoding: .utf8
    )
    try """
    {"kind":"neoanki","version":3,"root":"root","parts":["items/items.jsonl"]}
    {"kind":"type","id":"Study","name":"Included Study","fields":[{"id":"front","name":"Front","type":"text","required":true},{"id":"back","name":"Back","type":"text","required":true}],"templates":[{"name":"Card","prompt":[{"field":"front"}],"answer":[{"field":"back"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}
    {"kind":"deck","id":"root","name":"Included","itemTypes":["Study"],"defaultType":"Study"}
    """.write(
        to: bundle.appendingPathComponent("deck.jsonl"),
        atomically: true,
        encoding: .utf8
    )

    let repository = try SQLiteLibraryRepository(
        databaseURL: directory.appendingPathComponent("library.sqlite")
    )
    try await repository.bootstrap()
    _ = try await repository.importAuthoredDeck(from: bundle)
    let model = LibraryFeatureModel(library: repository)
    await model.bootstrap(startSync: false)
    let included = try #require(model.includedItemTypeGroups.first?.itemTypes.first)

    #expect(model.includedItemTypeOwner(id: included.id) != nil)
    #expect(try await model.itemTypeEditingImpact(id: included.id) == .init(
        itemCount: 0,
        deckCount: 0,
        unassignedItemCount: 0
    ))
    var riskyEdit = included
    riskyEdit.fields.removeLast()
    let impact = try await model.itemTypeSchemaChangeImpact(from: included, to: riskyEdit)
    #expect(impact.affectedItemCount == 0)
    #expect(impact.requiresConfirmation == false)

    try await model.unlockItemType(id: included.id)
    #expect(model.includedItemTypeOwner(id: included.id) == nil)
    #expect(model.itemTypes.contains { $0.id == included.id })
}

@Test @MainActor func libraryFeatureAcceptsLegacyAggregateWithoutOfferingPartialStudio() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-legacy-library-aggregate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sqlite = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    let legacyRepository = LegacyLibraryRepositoryConformer(base: sqlite)
    let _: any LibraryItemTypeEditingSafeguarding = legacyRepository
    let legacy: any LibraryRepository = legacyRepository
    let model = LibraryFeatureModel(library: legacy)

    await model.bootstrap(startSync: false)

    #expect(model.loadState == .ready)
    #expect(model.itemTypes.isEmpty == false)
    #expect(model.itemTypeStudioLibrary == nil)
}

@Test @MainActor func sqliteLibraryOffersCompileTimeSafeStudioProjection() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-studio-library-projection-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sqlite = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await sqlite.bootstrap()
    let libraryModel = LibraryFeatureModel(library: sqlite)
    let studioLibrary = try #require(libraryModel.itemTypeStudioLibrary)
    let studioModel = ItemTypesFeatureModel(library: studioLibrary)

    await studioModel.load()

    #expect(studioModel.loadState == .ready)
}
