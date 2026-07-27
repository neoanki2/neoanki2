import Foundation

public struct QuarantinedItemTypeDefinition: Sendable, Equatable, Identifiable {
    public let persistedID: String
    public let name: String

    public var id: String { persistedID }
    public var repairableID: UUID? { UUID(uuidString: persistedID) }

    public init(persistedID: String, name: String) {
        self.persistedID = persistedID
        self.name = name
    }
}

public struct ItemTypeLoadResult: Sendable, Equatable {
    public let itemTypes: [ItemType]
    public let corruptions: [QuarantinedItemTypeDefinition]

    public init(itemTypes: [ItemType], corruptions: [QuarantinedItemTypeDefinition]) {
        self.itemTypes = itemTypes
        self.corruptions = corruptions
    }
}

/// An item loaded from persistence with summary fields for list display.
public struct SavedItemSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let itemTypeID: UUID
    public let itemTypeName: String
    public let title: String
    public let subtitle: String
    public let cardCount: Int
    public let deckID: UUID?
    public let createdAt: Date

    public init(
        id: UUID,
        itemTypeID: UUID,
        itemTypeName: String,
        title: String,
        subtitle: String,
        cardCount: Int,
        deckID: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.itemTypeID = itemTypeID
        self.itemTypeName = itemTypeName
        self.title = title
        self.subtitle = subtitle
        self.cardCount = cardCount
        self.deckID = deckID
        self.createdAt = createdAt
    }
}

/// The durable result of a review. The log identifier is the only supported
/// target for a compensating revert.
public struct ReviewSubmission: Sendable, Equatable {
    public let memory: MemoryState
    public let reviewLogID: UUID

    public init(memory: MemoryState, reviewLogID: UUID) {
        self.memory = memory
        self.reviewLogID = reviewLogID
    }
}

private extension FieldType {
    var requiresStructuredImportValue: Bool {
        switch self {
        case .audio, .image, .gif, .video, .cloze:
            true
        case .text, .richText, .number:
            false
        }
    }
}

/// Persistence for items and generated cards.
public actor ItemStore {
    let database: SQLiteDatabase
    private let schedulerOverride: (any Scheduler)?
    private let profileID: String
    private var fsrsParameters = FSRSScheduler.Parameters()
    let mediaStore: MediaStore?
    private let starterItemTypes: [ItemType]

    public init(
        databaseURL: URL,
        scheduler: (any Scheduler)? = nil,
        profileID: String = "default",
        mediaStore: MediaStore? = nil,
        starterItemTypes: [ItemType] = BuiltInItemTypes.all
    ) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: databaseURL)
        schedulerOverride = scheduler
        self.profileID = profileID.isEmpty ? "default" : profileID
        self.starterItemTypes = starterItemTypes
        if let mediaStore {
            self.mediaStore = mediaStore
        } else {
            self.mediaStore = try? MediaStore(rootDirectory: MediaStore.defaultRoot(near: databaseURL))
        }
    }

    public var media: MediaStore? {
        mediaStore
    }

    /// Opens the database, runs migrations, and applies the configured
    /// first-run starter set once for this library.
    public func bootstrap() async throws {
        for itemType in starterItemTypes {
            try ItemTypeValidation.validate(itemType)
        }
        try await database.migrate()
        await mediaStore?.attachMetadataDatabase(database)
        try await database.seedStarterItemTypesIfNeeded(starterItemTypes)
        if schedulerOverride == nil,
           let saved = try await database.fetchSchedulerParameters(profileID: profileID) {
            fsrsParameters = saved
        }
    }

    public func defaultItemType() async throws -> ItemType {
        try await itemType(id: BuiltInItemTypes.basicID)
    }

    public func itemType(id: UUID) async throws -> ItemType {
        guard let itemType = try await database.fetchItemType(id: id) else {
            throw DatabaseError.itemTypeNotFound(id)
        }
        return itemType
    }

    /// Persists a user-defined item type.
    @discardableResult
    public func createItemType(_ itemType: ItemType) async throws -> ItemType {
        try ItemTypeValidation.validate(itemType)
        try await database.insertItemType(itemType)
        return itemType
    }

    /// Returns all persisted item types ordered by name.
    public func listItemTypes() async throws -> [ItemType] {
        try await database.fetchAllItemTypes()
    }

    /// Loads each definition independently so one malformed row cannot hide
    /// unaffected item types.
    public func loadItemTypes() async throws -> ItemTypeLoadResult {
        try await database.fetchItemTypesWithCorruption()
    }

    /// Archives the malformed bytes, then replaces that row with a minimal,
    /// editable definition. This never silently discards the original data.
    public func repairItemTypeDefinition(id: UUID, now: Date = .now) async throws -> ItemType {
        try await database.repairItemTypeDefinition(id: id, now: now)
    }

    public func countItems(itemTypeID: UUID) async throws -> Int {
        try await database.countItems(itemTypeID: itemTypeID)
    }

    /// Deletes an item type when it has no items. First-run starters are regular
    /// user-owned types after seeding and can be removed.
    @discardableResult
    public func deleteItemType(id: UUID) async throws -> Bool {
        guard try await database.fetchItemType(id: id) != nil else { return false }
        let itemCount = try await database.countItems(itemTypeID: id)
        if itemCount > 0 {
            throw DatabaseError.invalidItemType("Remove all items of this type before deleting it.")
        }
        try await database.deleteItemType(id: id)
        return true
    }

    /// Updates an item type and syncs cards for existing items.
    @discardableResult
    public func updateItemType(_ itemType: ItemType, now: Date = .now) async throws -> ItemType {
        let previous = try await database.fetchItemType(id: itemType.id)
        try ItemTypeValidation.validate(itemType)
        try await database.updateItemTypeAndSyncCards(
            previous: previous,
            updated: itemType,
            now: now
        )

        return itemType
    }

    /// Persists a deck used for organization only.
    @discardableResult
    public func createDeck(_ deck: Deck) async throws -> Deck {
        try await database.insertDeck(deck)
        return deck
    }

    public func deck(id: UUID) async throws -> Deck {
        guard let deck = try await database.fetchDeck(id: id) else {
            throw DatabaseError.deckNotFound(id)
        }
        return deck
    }

    /// Returns all persisted decks ordered by name.
    public func listDecks() async throws -> [Deck] {
        try await database.fetchAllDecks()
    }

    /// Returns deck metadata with direct item counts and due counts including subdecks.
    public func deckSummaries(asOf now: Date = .now) async throws -> [DeckSummary] {
        let decks = try await database.fetchAllDecks()
        let summaries = decks.map { deck in
            DeckSummary(
                id: deck.id,
                name: deck.name,
                parentID: deck.parentID,
                itemCount: 0,
                dueCount: 0
            )
        }

        var itemCounts: [UUID: Int] = [:]
        var dueCounts: [UUID: Int] = [:]

        for deck in decks {
            itemCounts[deck.id] = try await database.countItems(deckID: deck.id)
        }

        for deck in decks {
            let scope = DeckTree.descendantIDs(of: deck.id, in: summaries)
            dueCounts[deck.id] = try await database.countDueCards(deckIDs: scope, asOf: now)
        }

        return decks.map { deck in
            DeckSummary(
                id: deck.id,
                name: deck.name,
                parentID: deck.parentID,
                itemCount: itemCounts[deck.id, default: 0],
                dueCount: dueCounts[deck.id, default: 0]
            )
        }
    }

    /// Renames or reparents a deck. Rejects cycles.
    @discardableResult
    public func updateDeck(_ deck: Deck) async throws -> Deck {
        guard try await database.fetchDeck(id: deck.id) != nil else {
            throw DatabaseError.deckNotFound(deck.id)
        }

        if let parentID = deck.parentID {
            guard try await database.fetchDeck(id: parentID) != nil else {
                throw DatabaseError.deckNotFound(parentID)
            }
        }

        let summaries = try await deckSummaries()
        if DeckTree.wouldCreateCycle(deckID: deck.id, newParentID: deck.parentID, in: summaries) {
            throw DatabaseError.invalidDeck("A deck can't be moved inside itself.")
        }

        try await database.updateDeck(deck)
        return deck
    }

    /// Deletes a deck, all nested subdecks, and every item they contain.
    @discardableResult
    public func deleteDeck(id: UUID) async throws -> Bool {
        guard try await database.fetchDeck(id: id) != nil else { return false }

        let summaries = try await deckSummaries()
        let descendantIDs = DeckTree.descendantIDs(of: id, in: summaries)
        try await database.deleteDeckRecursively(descendantIDs: descendantIDs)
        _ = try? await collectMediaGarbage()

        return true
    }

    /// Deletes every unassigned item and its generated cards.
    @discardableResult
    public func deleteAllUnassignedItems(now: Date = .now) async throws -> Int {
        let deleted = try await database.deleteAllUnassignedItems(deletedAt: now)
        if deleted > 0 {
            _ = try? await collectMediaGarbage()
        }
        return deleted
    }

    /// Moves an item to another deck and syncs generated cards.
    @discardableResult
    public func updateItemDeck(itemID: UUID, deckID: UUID?) async throws -> Bool {
        guard try await database.fetchItem(id: itemID) != nil else { return false }

        if let deckID {
            guard try await database.fetchDeck(id: deckID) != nil else {
                throw DatabaseError.deckNotFound(deckID)
            }
        }

        try await database.updateItemDeckSync(itemID: itemID, deckID: deckID)

        return true
    }

    /// Saves an item and the cards generated from its item type templates.
    @discardableResult
    public func createItem(_ item: Item, now: Date = .now) async throws -> SavedItemSummary {
        guard let itemType = try await database.fetchItemType(id: item.itemTypeID) else {
            throw DatabaseError.itemTypeNotFound(item.itemTypeID)
        }

        if let deckID = item.deckID {
            guard try await database.fetchDeck(id: deckID) != nil else {
                throw DatabaseError.deckNotFound(deckID)
            }
        }

        try validate(item, against: itemType)
        let cards = CardGenerator.cards(for: item, type: itemType, now: now)
        let mediaDescriptors = try await newMediaDescriptors(in: item, comparedTo: nil)

        try await database.insertItemWithCards(
            item,
            cards: cards,
            createdAt: now,
            updatedAt: now,
            mediaDescriptors: mediaDescriptors
        )

        return SavedItemSummary(
            id: item.id,
            itemTypeID: itemType.id,
            itemTypeName: itemType.name,
            title: ItemDisplay.title(for: item, in: itemType),
            subtitle: ItemDisplay.subtitle(for: item, in: itemType),
            cardCount: cards.count,
            deckID: item.deckID,
            createdAt: now
        )
    }

    public func listItems(scope: DeckScope = .allDecks) async throws -> [SavedItemSummary] {
        let persisted: [PersistedItem]
        switch scope {
        case .allDecks:
            persisted = try await database.fetchItems()
        case .unassigned:
            persisted = try await database.fetchUnassignedItems()
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let summaries = try await deckSummaries()
                let deckIDs = DeckTree.descendantIDs(of: deckID, in: summaries)
                persisted = try await database.fetchItems(deckIDs: deckIDs)
            } else {
                persisted = try await database.fetchItems(deckID: deckID)
            }
        }
        return try await summaries(for: persisted)
    }

    /// Returns all items regardless of deck assignment.
    public func listItems() async throws -> [SavedItemSummary] {
        try await listItems(scope: .allDecks)
    }

    /// Returns cards due for review at `now`, hydrated with item and template data.
    public func fetchDueCards(
        scope: DeckScope = .allDecks,
        asOf now: Date = .now,
        limit: Int? = nil
    ) async throws -> [DueCard] {
        let cards: [Card]
        switch scope {
        case .allDecks:
            cards = try await database.fetchDueCards(asOf: now, limit: limit)
        case .unassigned:
            cards = try await database.fetchUnassignedDueCards(asOf: now, limit: limit)
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let summaries = try await deckSummaries(asOf: now)
                let deckIDs = DeckTree.descendantIDs(of: deckID, in: summaries)
                cards = try await database.fetchDueCards(deckIDs: deckIDs, asOf: now, limit: limit)
            } else {
                cards = try await database.fetchDueCards(deckIDs: [deckID], asOf: now, limit: limit)
            }
        }
        return try await hydrateDueCards(cards)
    }

    /// Returns all due cards regardless of deck assignment.
    public func fetchDueCards(asOf now: Date = .now, limit: Int? = nil) async throws -> [DueCard] {
        try await fetchDueCards(scope: .allDecks, asOf: now, limit: limit)
    }

    /// Loads a persisted item with its item type for detail views.
    public func fetchItem(id: UUID) async throws -> (item: Item, itemType: ItemType)? {
        guard
            let persisted = try await database.fetchItem(id: id),
            let itemType = try await database.fetchItemType(id: persisted.item.itemTypeID)
        else {
            return nil
        }
        return (persisted.item, itemType)
    }

    /// Updates item content and applies media reference deltas atomically.
    @discardableResult
    public func updateItem(_ item: Item, now: Date = .now) async throws -> SavedItemSummary {
        guard let previous = try await database.fetchItem(id: item.id) else {
            throw DatabaseError.invalidMediaAsset("The item being edited no longer exists.")
        }
        guard previous.item.itemTypeID == item.itemTypeID,
              let itemType = try await database.fetchItemType(id: item.itemTypeID)
        else {
            throw DatabaseError.itemTypeNotFound(item.itemTypeID)
        }
        if let deckID = item.deckID {
            guard try await database.fetchDeck(id: deckID) != nil else {
                throw DatabaseError.deckNotFound(deckID)
            }
        }

        try validate(item, against: itemType)
        let mediaDescriptors = try await newMediaDescriptors(in: item, comparedTo: previous.item)
        let desiredCards = CardGenerator.cards(for: item, type: itemType, now: now)
        try await database.updateItemWithMedia(
            item,
            desiredCards: desiredCards,
            updatedAt: now,
            mediaDescriptors: mediaDescriptors
        )
        return SavedItemSummary(
            id: item.id,
            itemTypeID: itemType.id,
            itemTypeName: itemType.name,
            title: ItemDisplay.title(for: item, in: itemType),
            subtitle: ItemDisplay.subtitle(for: item, in: itemType),
            cardCount: desiredCards.count,
            deckID: item.deckID,
            createdAt: previous.createdAt
        )
    }

    /// Deletes an item and its generated cards.
    @discardableResult
    public func deleteItem(id: UUID, now: Date = .now) async throws -> Bool {
        let deleted = try await database.deleteItemWithMedia(id: id, deletedAt: now)
        if deleted {
            _ = try? await collectMediaGarbage()
        }
        return deleted
    }

    public func mediaAsset(hash: String) async throws -> MediaAsset? {
        try await database.fetchMediaAsset(hash: hash)
    }

    /// Deletes only zero-reference assets, retaining metadata when deletion is unsafe.
    @discardableResult
    public func collectMediaGarbage(asOf now: Date = .now) async throws -> Int {
        guard let mediaStore else { return 0 }
        try await database.removeExpiredMediaReservations(asOf: now)
        let orphans = try await database.fetchOrphanedMediaAssets()
        var collected = 0
        for asset in orphans {
            try await mediaStore.removeOrphan(asset)
            try await database.deleteMediaAssetIfOrphaned(hash: asset.hash)
            collected += 1
        }
        return collected
    }

    public func dueCount(scope: DeckScope = .allDecks, asOf now: Date = .now) async throws -> Int {
        switch scope {
        case .allDecks:
            return try await database.countDueCards(asOf: now)
        case .unassigned:
            return try await database.countUnassignedDueCards(asOf: now)
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let summaries = try await deckSummaries(asOf: now)
                let deckIDs = DeckTree.descendantIDs(of: deckID, in: summaries)
                return try await database.countDueCards(deckIDs: deckIDs, asOf: now)
            }
            return try await database.countDueCards(deckID: deckID, asOf: now)
        }
    }

    public func dueCount(asOf now: Date = .now) async throws -> Int {
        try await dueCount(scope: .allDecks, asOf: now)
    }

    public func unassignedDueCount(asOf now: Date = .now) async throws -> Int {
        try await dueCount(scope: .unassigned, asOf: now)
    }

    public func unassignedItemCount() async throws -> Int {
        try await database.countUnassignedItems()
    }

    /// Applies a review rating, updates card memory, and appends a review log.
    @discardableResult
    public func submitReview(
        cardID: UUID,
        rating: ReviewRating,
        now: Date = .now,
        durationMs: Int = 0
    ) async throws -> MemoryState {
        try await submitReviewWithReceipt(
            cardID: cardID,
            rating: rating,
            now: now,
            durationMs: durationMs
        ).memory
    }

    /// Applies a review and returns the exact append-only log entry that can be
    /// compensated later.
    public func submitReviewWithReceipt(
        cardID: UUID,
        rating: ReviewRating,
        now: Date = .now,
        durationMs: Int = 0
    ) async throws -> ReviewSubmission {
        guard var card = try await database.fetchCard(id: cardID) else {
            throw DatabaseError.cardNotFound(cardID)
        }

        let memoryBefore = card.memory
        let phaseBefore = card.memory.phase
        let elapsedDays: Double
        if let lastReview = card.memory.lastReview {
            elapsedDays = max(now.timeIntervalSince(lastReview) / 86_400, 0)
        } else {
            elapsedDays = 0
        }

        let scheduledDays = max(
            card.memory.lastReview.map { card.memory.due.timeIntervalSince($0) / 86_400 } ?? 0,
            0
        )

        let scheduler: any Scheduler = schedulerOverride
            ?? LearningScheduler(parameters: fsrsParameters)
        let nextMemory = scheduler.schedule(card.memory, rating: rating, now: now)
        card.memory = nextMemory

        let log = ReviewLog(
            cardID: card.id,
            reviewedAt: now,
            rating: rating,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            phaseBefore: phaseBefore,
            durationMs: durationMs
        )

        try await database.persistReview(
            cardID: card.id,
            memoryBefore: memoryBefore,
            memoryAfter: nextMemory,
            log: log
        )

        return ReviewSubmission(memory: nextMemory, reviewLogID: log.id)
    }

    public func revertReview(reviewLogID: UUID, now: Date = .now) async throws {
        try await database.revertReview(reviewLogID: reviewLogID, revertedAt: now)
    }

    /// Active review count retained for source compatibility with statistics callers.
    public func reviewLogCount(for cardID: UUID) async throws -> Int {
        try await activeReviewLogCount(for: cardID)
    }

    public func rawReviewLogCount(for cardID: UUID) async throws -> Int {
        try await database.countRawReviewLogs(for: cardID)
    }

    public func activeReviewLogCount(for cardID: UUID) async throws -> Int {
        try await database.countActiveReviewLogs(for: cardID)
    }

    public func schedulingParameters() -> FSRSScheduler.Parameters {
        fsrsParameters
    }

    /// Fits and persists scheduler weights for this store's profile.
    ///
    /// Only active, decodable review logs participate. The minimum-data gate
    /// is based on repeated-review outcomes rather than raw log rows.
    @discardableResult
    public func optimizeScheduling(
        minimumObservations: Int = 100,
        now: Date = .now
    ) async throws -> FSRSOptimizationResult {
        let logs = try await database.fetchActiveReviewLogs()
        let optimizer = FSRSOptimizer(minimumObservations: minimumObservations)
        let result = try optimizer.optimize(logs: logs, startingAt: fsrsParameters)
        guard result.improved else { return result }

        try await database.saveSchedulerParameters(
            result.parameters,
            profileID: profileID,
            optimizedAt: now,
            sampleCount: result.observationCount,
            logLoss: result.optimizedLoss
        )
        fsrsParameters = result.parameters
        return result
    }

    /// Imports rows parsed by a native adapter into an existing item type.
    @discardableResult
    public func importItems(
        from data: Data,
        adapter: some ImportAdapter,
        itemTypeID: UUID? = nil,
        context: ImportContext = ImportContext(),
        now: Date = .now
    ) async throws -> Int {
        try ImportLimits.validatePayloadSize(data)
        let payload = try adapter.parse(data)
        try ImportLimits.validateDecodedPayload(payload)
        let resolvedType: ItemType

        if let itemTypeID {
            resolvedType = try await itemType(id: itemTypeID)
        } else if let byName = try await database.fetchItemType(named: payload.itemTypeName) {
            resolvedType = byName
        } else {
            throw ImportError.itemTypeNotFound(payload.itemTypeName)
        }

        if itemTypeID == nil, resolvedType.name != payload.itemTypeName {
            throw ImportError.invalidFormat("Item type name mismatch.")
        }

        var entries: [(item: Item, cards: [Card])] = []
        entries.reserveCapacity(payload.rows.count)
        let importScope = UUID()

        do {
            for row in payload.rows {
                let fields = try await mapImportRow(
                    row,
                    to: resolvedType,
                    context: context,
                    supportsStructuredFields: adapter.supportsStructuredFields,
                    mediaReservationScope: importScope
                )
                let item = Item(itemTypeID: resolvedType.id, fields: fields, tags: row.tags)
                try validate(item, against: resolvedType)
                entries.append((
                    item: item,
                    cards: CardGenerator.cards(for: item, type: resolvedType, now: now)
                ))
            }

            try await database.insertItemsWithCards(entries, createdAt: now, updatedAt: now)
            // Persistence is already committed. Reservation cleanup is
            // best-effort so callers never receive a failure for an import
            // that is present in the library.
            try? await mediaStore?.releaseReservations(scopeID: importScope)
            return entries.count
        } catch {
            try? await mediaStore?.rollbackReservations(scopeID: importScope)
            throw error
        }
    }

    private func newMediaDescriptors(
        in item: Item,
        comparedTo previous: Item?
    ) async throws -> [String: MediaAssetDescriptor] {
        var previousCounts: [String: Int] = [:]
        if let previous {
            for ref in mediaReferences(in: previous) {
                previousCounts[mediaIdentity(ref), default: 0] += 1
            }
        }

        var descriptors: [String: MediaAssetDescriptor] = [:]
        for ref in mediaReferences(in: item) {
            let identity = mediaIdentity(ref)
            if previousCounts[identity, default: 0] > 0 {
                previousCounts[identity, default: 0] -= 1
                continue
            }
            guard let mediaStore else {
                throw DatabaseError.invalidMediaAsset("Media storage is unavailable.")
            }
            let descriptor = try await mediaStore.descriptor(for: ref)
            if let existing = descriptors[descriptor.hash], existing != descriptor {
                throw DatabaseError.invalidMediaAsset("Conflicting media metadata uses the same hash.")
            }
            descriptors[descriptor.hash] = descriptor
        }
        return descriptors
    }

    private func mediaReferences(in item: Item) -> [MediaRef] {
        item.fields.compactMap { field in
            guard case let .media(ref) = field.value else { return nil }
            return ref
        }
    }

    private func mediaIdentity(_ ref: MediaRef) -> String {
        "\(ref.assetHash)|\(ref.kind.rawValue)|\(ref.fileExtension)"
    }

    private func mapImportRow(
        _ row: ImportRow,
        to itemType: ItemType,
        context: ImportContext,
        supportsStructuredFields: Bool,
        mediaReservationScope: UUID
    ) async throws -> [FieldValue] {
        var values: [FieldValue] = []

        for field in itemType.fields {
            if let structured = row.structuredFields[field.name] {
                let value = try await contentValue(
                    from: structured,
                    field: field,
                    context: context,
                    mediaReservationScope: mediaReservationScope
                )
                if value.isEmpty, field.isRequired {
                    throw DatabaseError.requiredFieldEmpty(field.name)
                }
                if !value.isEmpty {
                    values.append(FieldValue(fieldID: field.id, value: value))
                }
                continue
            }

            guard let text = row.fieldValues[field.name] else {
                if field.isRequired {
                    throw DatabaseError.requiredFieldEmpty(field.name)
                }
                continue
            }

            if !supportsStructuredFields, field.type.requiresStructuredImportValue {
                throw ImportError.invalidFormat(
                    "CSV cannot import the structured field \"\(field.name)\". Use JSON for cloze and media fields."
                )
            }
            try ImportLimits.validateFieldString(text, fieldName: field.name)
            values.append(FieldValue(fieldID: field.id, value: field.contentValue(from: text)))
        }

        for key in row.fieldValues.keys where itemType.field(named: key) == nil {
            throw ImportError.unknownField(key)
        }
        for key in row.structuredFields.keys where itemType.field(named: key) == nil {
            throw ImportError.unknownField(key)
        }

        return values
    }

    private func contentValue(
        from structured: StructuredFieldValue,
        field: FieldDef,
        context: ImportContext,
        mediaReservationScope: UUID
    ) async throws -> ContentValue {
        switch structured {
        case let .text(string):
            try ImportLimits.validateFieldString(string, fieldName: field.name)
            return field.contentValue(from: string)
        case let .cloze(text, blanks):
            try ImportLimits.validateFieldString(text, fieldName: field.name)
            try ClozeValidation.validate(text: text, blanks: blanks)
            return field.contentValue(fromClozeText: text, blanks: blanks)
        case let .mediaPath(path):
            guard let kind = field.type.mediaKind else {
                throw ImportError.invalidFormat("Field \"\(field.name)\" is not a media field.")
            }
            guard let mediaStore else {
                throw ImportError.invalidFormat("Media import requires a media store.")
            }
            let resolved = try resolveImportPath(path, baseDirectory: context.baseDirectory)
            let ref = try await mediaStore.ingest(
                url: resolved,
                kind: kind,
                reservationScope: mediaReservationScope
            )
            return .media(ref)
        case let .mediaBase64(base64, declaredExtension, altText):
            guard let kind = field.type.mediaKind else {
                throw ImportError.invalidFormat("Field \"\(field.name)\" is not a media field.")
            }
            guard let mediaStore else {
                throw ImportError.invalidFormat("Media import requires a media store.")
            }
            try ImportLimits.validateBase64EncodedSize(base64, kind: kind, fieldName: field.name)
            guard let data = Data(base64Encoded: base64) else {
                throw ImportError.invalidFormat("Invalid base64 for field \"\(field.name)\".")
            }
            guard data.count <= MediaValidation.maxBytes(for: kind) else {
                throw ImportError.invalidFormat("Media in field \"\(field.name)\" exceeds its size limit.")
            }
            if let altText {
                try ImportLimits.validateFieldString(altText, fieldName: "\(field.name) alt text")
            }
            let inferredExtension: String
            do {
                inferredExtension = try MediaValidation.inferredExtension(data: data, expectedKind: kind)
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? "The bytes are invalid."
                throw ImportError.invalidFormat("Media in field \"\(field.name)\" is invalid. \(detail)")
            }
            if let declaredExtension {
                let normalized = declaredExtension.lowercased() == "jpeg"
                    ? "jpg"
                    : declaredExtension.lowercased()
                guard normalized == inferredExtension else {
                    throw ImportError.invalidFormat(
                        "Media in field \"\(field.name)\" does not match its fileExtension."
                    )
                }
            }
            let ref = try await mediaStore.ingest(
                data: data,
                kind: kind,
                fileExtension: inferredExtension,
                altText: altText,
                reservationScope: mediaReservationScope
            )
            return .media(ref)
        }
    }

    private func resolveImportPath(_ path: String, baseDirectory: URL?) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ImportError.invalidFormat("Media path is empty.")
        }
        guard !NSString(string: trimmed).isAbsolutePath else {
            throw ImportError.invalidFormat("Absolute media paths are not allowed.")
        }
        guard let baseDirectory else {
            throw ImportError.invalidFormat("Media paths require an import base directory.")
        }
        guard baseDirectory.isFileURL else {
            throw ImportError.invalidFormat("Import base directory is invalid.")
        }

        let base = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ImportError.invalidFormat("Import base directory is invalid.")
        }

        let resolved = baseDirectory
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let baseComponents = base.pathComponents
        let resolvedComponents = resolved.pathComponents
        guard
            resolvedComponents.count > baseComponents.count,
            resolvedComponents.prefix(baseComponents.count).elementsEqual(baseComponents)
        else {
            throw ImportError.invalidFormat("Media path escapes import directory.")
        }
        return resolved
    }

    private func summaries(for persisted: [PersistedItem]) async throws -> [SavedItemSummary] {
        var summaries: [SavedItemSummary] = []
        summaries.reserveCapacity(persisted.count)

        for entry in persisted {
            // Malformed definitions are reported by loadItemTypes(), where
            // callers receive the persisted ID and the archive-before-repair
            // path. Keep unrelated item rows usable in the meantime.
            guard let itemType = try await database.fetchValidatedItemType(
                id: entry.item.itemTypeID
            ) else { continue }
            let cardCount = try await database.countCards(for: entry.item.id)
            summaries.append(
                SavedItemSummary(
                    id: entry.item.id,
                    itemTypeID: itemType.id,
                    itemTypeName: itemType.name,
                    title: ItemDisplay.title(for: entry.item, in: itemType),
                    subtitle: ItemDisplay.subtitle(for: entry.item, in: itemType),
                    cardCount: cardCount,
                    deckID: entry.item.deckID,
                    createdAt: entry.createdAt
                )
            )
        }
        return summaries
    }

    private func hydrateDueCards(_ cards: [Card]) async throws -> [DueCard] {
        var dueCards: [DueCard] = []
        dueCards.reserveCapacity(cards.count)

        for card in cards {
            guard let persisted = try await database.fetchItem(id: card.itemID) else {
                continue
            }
            // The linked card remains persisted and becomes available again
            // after repairItemTypeDefinition archives and repairs its type.
            guard let itemType = try await database.fetchValidatedItemType(
                      id: persisted.item.itemTypeID
                  ),
                  let template = itemType.templates.first(where: { $0.id == card.templateID })
            else { continue }

            dueCards.append(
                DueCard(
                    card: card,
                    item: persisted.item,
                    itemType: itemType,
                    template: template
                )
            )
        }

        return dueCards
    }

    private func validate(_ item: Item, against itemType: ItemType) throws {
        for fieldValue in item.fields {
            switch fieldValue.value {
            case let .cloze(text, blanks):
                try ClozeValidation.validate(text: text, blanks: blanks)
            case let .media(ref):
                guard ref.isValidStoredReference else {
                    throw MediaError.sandboxViolation
                }
            default:
                break
            }
        }

        for field in itemType.fields {
            let value = item.value(for: field.id)
            if field.isRequired {
                guard let value, !value.isEmpty else {
                    throw DatabaseError.requiredFieldEmpty(field.name)
                }
            }

            if case let .media(ref)? = value, field.type.mediaKind != ref.kind {
                throw MediaError.unsupportedFormat(ref.kind)
            }
        }
    }

}
