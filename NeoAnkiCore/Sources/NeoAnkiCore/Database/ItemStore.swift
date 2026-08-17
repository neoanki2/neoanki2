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

public struct ColdLibrarySnapshot: Sendable, Equatable {
    public let itemTypes: ItemTypeLoadResult
    public let items: [SavedItemSummary]
    public let deckSummaries: [DeckSummary]
    public let allDecksSummary: ScopeSummary
    public let unassignedSummary: ScopeSummary
    public let selectedScopeSummary: ScopeSummary
}

/// The data needed to render the library home without materializing browse
/// rows. Browse content is intentionally a separate, on-demand load.
public struct ColdLibraryHomeSnapshot: Sendable, Equatable {
    public let itemTypes: ItemTypeLoadResult
    public let deckSummaries: [DeckSummary]
    public let allDecksSummary: ScopeSummary
    public let unassignedSummary: ScopeSummary
    public let selectedScopeSummary: ScopeSummary

    public init(
        itemTypes: ItemTypeLoadResult,
        deckSummaries: [DeckSummary],
        allDecksSummary: ScopeSummary,
        unassignedSummary: ScopeSummary,
        selectedScopeSummary: ScopeSummary
    ) {
        self.itemTypes = itemTypes
        self.deckSummaries = deckSummaries
        self.allDecksSummary = allDecksSummary
        self.unassignedSummary = unassignedSummary
        self.selectedScopeSummary = selectedScopeSummary
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
    /// Rolled-up scheduling state. Optional so callers that only describe a
    /// freshly written item need not query for it.
    public let schedule: ItemScheduleSummary?

    public init(
        id: UUID,
        itemTypeID: UUID,
        itemTypeName: String,
        title: String,
        subtitle: String,
        cardCount: Int,
        deckID: UUID? = nil,
        createdAt: Date,
        schedule: ItemScheduleSummary? = nil
    ) {
        self.id = id
        self.itemTypeID = itemTypeID
        self.itemTypeName = itemTypeName
        self.title = title
        self.subtitle = subtitle
        self.cardCount = cardCount
        self.deckID = deckID
        self.createdAt = createdAt
        self.schedule = schedule
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
    private static let studyDayRolloverMetadataKey = "study_day_rollover_minutes"
    static let studyDayRolloverMetadataKeyForSync = studyDayRolloverMetadataKey
    private static let optimizationAttemptMetadataPrefix = "fsrs_optimization_attempt."

    private struct CachedItemList {
        let token: DatabaseCacheToken
        let items: [SavedItemSummary]
    }

    private struct CachedScopeSummary {
        let token: DatabaseCacheToken
        let summary: ScopeSummary
        let calculatedAt: Date
        let validUntil: Date?

        func isValid(token currentToken: DatabaseCacheToken, asOf now: Date) -> Bool {
            guard token == currentToken else { return false }
            guard now >= calculatedAt else { return false }
            return validUntil.map { now < $0 } ?? true
        }
    }

    private struct CachedDeckSummaries {
        let token: DatabaseCacheToken
        let summaries: [DeckSummary]
        let calculatedAt: Date
        let validUntil: Date

        func isValid(token currentToken: DatabaseCacheToken, asOf now: Date) -> Bool {
            token == currentToken && now >= calculatedAt && now < validUntil
        }
    }

    let database: SQLiteDatabase
    let schedulerOverride: (any Scheduler)?
    let profileID: String
    var fsrsParameters = FSRSScheduler.Parameters()
    let mediaStore: MediaStore?
    private let localAPITransferStateFile: URL
    private var itemListCache: [DeckScope: CachedItemList] = [:]
    private var scopeSummaryCache: [DeckScope: CachedScopeSummary] = [:]
    private var deckSummariesCache: CachedDeckSummaries?
    private let starterItemTypes: [ItemType]
    private var externalMutationInProgress = false
    private var externalMutationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Serializes adapter-level read/check/write mutation sequences over this
    /// library. The database commands remain the source of validation and
    /// transactionality; this lease prevents two adapters from both passing
    /// the same optimistic-revision check before either command commits.
    public func acquireExternalMutationSlot() async {
        if !externalMutationInProgress {
            externalMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            externalMutationWaiters.append(continuation)
        }
    }

    public func releaseExternalMutationSlot() {
        if externalMutationWaiters.isEmpty {
            externalMutationInProgress = false
        } else {
            externalMutationWaiters.removeFirst().resume()
        }
    }

    public init(
        databaseURL: URL,
        scheduler: (any Scheduler)? = nil,
        profileID: String = "default",
        mediaStore: MediaStore? = nil,
        starterItemTypes: [ItemType] = BuiltInItemTypes.all
    ) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        localAPITransferStateFile = directory
            .appendingPathComponent(".neoanki-api", isDirectory: true)
            .appendingPathComponent("transfers.plist", isDirectory: false)
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

    /// Private library-local storage used by the loopback API for resumable
    /// import and export jobs. It is intentionally not part of any HTTP model.
    public func localAPITransferStateURL() -> URL {
        localAPITransferStateFile
    }

    /// Creates a consistent private snapshot for non-mutating validation.
    /// Callers own and must remove the destination when finished.
    public func createValidationDatabaseSnapshot(at destination: URL) async throws {
        try await database.backup(to: destination)
    }

    public func libraryID() async throws -> UUID {
        try await database.libraryID()
    }

    /// Opens the database, runs migrations, and applies the configured
    /// first-run starter set once for this library.
    public func bootstrap() async throws {
        let bootstrapTime = Date.now
        for itemType in starterItemTypes {
            try ItemTypeValidation.validate(itemType)
        }
        try await database.migrate()
        try await database.ensureTemplateDefinitionFormat()
        await mediaStore?.attachMetadataDatabase(database)
        try await database.seedStarterItemTypesIfNeeded(starterItemTypes)
        try await ensureVersionedSchedulingBootstrap(now: bootstrapTime)
        try await migrateLegacyCardSchedulingIfNeeded(now: bootstrapTime)
    }

    /// Persists a deck and its learner-local new-card introduction policy.
    @discardableResult
    public func createDeck(_ deck: Deck) async throws -> Deck {
        try validateDeckLimit(deck.newCardsPerDay)
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

    public func studyDayRolloverMinutes() async throws -> Int {
        guard
            let stored = try await database.metadataValue(
                forKey: Self.studyDayRolloverMetadataKey
            ),
            let minutes = Int(stored),
            StudyDay.validRolloverMinutes.contains(minutes)
        else {
            return StudyDay.defaultRolloverMinutes
        }
        return minutes
    }

    public func setStudyDayRolloverMinutes(_ minutes: Int) async throws {
        guard StudyDay.validRolloverMinutes.contains(minutes) else {
            throw DatabaseError.invalidDeck("Study day rollover must be a valid local time.")
        }
        try await database.setMetadataValue(
            String(minutes),
            forKey: Self.studyDayRolloverMetadataKey
        )
    }

    func studyDayKey(asOf now: Date) async throws -> String {
        let rollover = try await studyDayRolloverMinutes()
        return StudyDay.key(for: now, rolloverMinutes: rollover)
    }

    /// Returns deck metadata with direct item counts and due counts including subdecks.
    public func deckSummaries(asOf now: Date = .now) async throws -> [DeckSummary] {
        let initialToken = try await database.cacheToken()
        if let cached = deckSummariesCache,
           cached.isValid(token: initialToken, asOf: now) {
            return cached.summaries
        }

        let decks = try await database.fetchAllDecks()
        let studyDay = try await studyDayKey(asOf: now)
        let tree = deckTreeSummaries(from: decks)
        let directItemCounts = try await database.countItemsGroupedByDeck()
        let directDueCounts = try await database.countDueCardsGroupedByDeck(
            asOf: now,
            studyDay: studyDay
        )

        let summaries = decks.map { deck in
            let scope = DeckTree.descendantIDs(of: deck.id, in: tree)
            let itemCount = scope.reduce(0) { partial, deckID in
                partial + directItemCounts[deckID, default: 0]
            }
            let dueCount = scope.reduce(0) { partial, deckID in
                partial + directDueCounts[deckID, default: 0]
            }
            return DeckSummary(
                id: deck.id,
                name: deck.name,
                parentID: deck.parentID,
                newCardsPerDay: deck.newCardsPerDay,
                itemCount: itemCount,
                dueCount: dueCount
            )
        }
        let rollover = try await studyDayRolloverMinutes()
        let nextRollover = StudyDay.nextRollover(
            after: now,
            rolloverMinutes: rollover
        )
        let nextDue = try await database.nextUnsuspendedCardDue(after: now)
        let validUntil = nextDue.map { min($0, nextRollover) } ?? nextRollover
        let finalToken = try await database.cacheToken()
        deckSummariesCache = CachedDeckSummaries(
            token: finalToken,
            summaries: summaries,
            calculatedAt: now,
            validUntil: validUntil
        )
        return summaries
    }

    /// Deck tree metadata without aggregate counts. Used when only descendant
    /// expansion is needed, not sidebar totals.
    private func deckTreeSummaries(from decks: [Deck]) -> [DeckSummary] {
        decks.map { deck in
            DeckSummary(
                id: deck.id,
                name: deck.name,
                parentID: deck.parentID,
                newCardsPerDay: deck.newCardsPerDay,
                itemCount: 0,
                dueCount: 0
            )
        }
    }

    func deckTreeSummaries() async throws -> [DeckSummary] {
        deckTreeSummaries(from: try await database.fetchAllDecks())
    }

    /// Scheduling summaries for specific items, read in batched queries.
    public func fetchItemBrowseSchedules(itemIDs: [UUID]) async throws -> [UUID: ItemBrowseSchedule] {
        let states = try await database.fetchItemCardStates(itemIDs: itemIDs)
        return states.mapValues { state in
            ItemBrowseSchedule(cardCount: state.cardCount, schedule: state.scheduleSummary)
        }
    }

    /// Renames or reparents a deck. Rejects cycles.
    @discardableResult
    public func updateDeck(_ deck: Deck) async throws -> Deck {
        try validateDeckLimit(deck.newCardsPerDay)
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

    /// Returns every card in a deck subtree to its never-reviewed state and
    /// removes the review history that produced its schedule. Items, deck
    /// settings, and card suspension state are preserved.
    @discardableResult
    public func resetDeckProgress(id: UUID, now: Date = .now) async throws -> Int {
        guard try await database.fetchDeck(id: id) != nil else {
            throw DatabaseError.deckNotFound(id)
        }

        let summaries = try await deckSummaries(asOf: now)
        let descendantIDs = DeckTree.descendantIDs(of: id, in: summaries)
        return try await database.resetDeckProgress(deckIDs: descendantIDs, now: now)
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
        var item = item
        item.tags = try normalizedTags(item.tags)
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
            createdAt: now,
            schedule: try await database.fetchItemCardState(itemID: item.id).scheduleSummary
        )
    }

    /// The default creation order is served straight from SQL. Other orders and
    /// searches are arranged in memory, where locale-aware title comparison and
    /// diacritic-insensitive matching behave the way a reader expects.
    public func listItems(
        scope: DeckScope = .allDecks,
        sort: ItemSortOrder = .createdAscending,
        search: String = ""
    ) async throws -> [SavedItemSummary] {
        let cacheable = sort == .createdAscending
            && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let initialToken = try await database.cacheToken()
        if cacheable,
           let cached = itemListCache[scope],
           cached.token == initialToken {
            return cached.items
        }

        let cardScope: CardScope
        switch scope {
        case .allDecks:
            cardScope = .all
        case .unassigned:
            cardScope = .unassigned
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let tree = try await deckTreeSummaries()
                let deckIDs = DeckTree.descendantIDs(of: deckID, in: tree)
                cardScope = .decks(deckIDs)
            } else {
                cardScope = .decks([deckID])
            }
        }

        // The projection stores a title and subtitle per item, so ordering and
        // searching no longer need the encoded field values. Rows whose item
        // type is malformed stay out of browsing: loadItemTypes() is where a
        // learner is told about them and offered the archive-before-repair path.
        let projected = try await database.fetchBrowseRows(scope: cardScope)
        let usable = try await browsableRows(projected)
        let arranged = cacheable
            ? usable
            : ItemBrowsing.arrange(usable, sort: sort, search: search)
        if cacheable {
            let finalToken = try await database.cacheToken()
            itemListCache[scope] = CachedItemList(token: finalToken, items: arranged)
        }
        return arranged
    }

    /// Returns all items regardless of deck assignment.
    public func listItems() async throws -> [SavedItemSummary] {
        try await listItems(scope: .allDecks)
    }

    public func coldLibrarySnapshot(
        scope: DeckScope = .allDecks,
        asOf now: Date = .now
    ) async throws -> ColdLibrarySnapshot {
        let itemTypes = try await loadItemTypes()
        let items = try await listItems(scope: scope, sort: .createdAscending)
        let decks = try await deckSummaries(asOf: now)
        let allDecks = try await scopeSummary(scope: .allDecks, asOf: now)
        let unassigned = try await scopeSummary(scope: .unassigned, asOf: now)
        let selected: ScopeSummary
        switch scope {
        case .allDecks:
            selected = allDecks
        case .unassigned:
            selected = unassigned
        case .deck:
            selected = try await scopeSummary(scope: scope, asOf: now)
        }
        return ColdLibrarySnapshot(
            itemTypes: itemTypes,
            items: items,
            deckSummaries: decks,
            allDecksSummary: allDecks,
            unassignedSummary: unassigned,
            selectedScopeSummary: selected
        )
    }

    /// Loads only the data visible on the initial home surface. Keeping this
    /// distinct from `coldLibrarySnapshot` preserves that API's full browse
    /// semantics for existing callers.
    public func coldLibraryHomeSnapshot(
        scope: DeckScope = .allDecks,
        asOf now: Date = .now
    ) async throws -> ColdLibraryHomeSnapshot {
        let itemTypes = try await loadItemTypes()
        let decks = try await deckSummaries(asOf: now)
        let allDecks = try await scopeSummary(scope: .allDecks, asOf: now)
        let unassigned = try await scopeSummary(scope: .unassigned, asOf: now)
        let selected: ScopeSummary
        switch scope {
        case .allDecks:
            selected = allDecks
        case .unassigned:
            selected = unassigned
        case .deck:
            selected = try await scopeSummary(scope: scope, asOf: now)
        }
        return ColdLibraryHomeSnapshot(
            itemTypes: itemTypes,
            deckSummaries: decks,
            allDecksSummary: allDecks,
            unassignedSummary: unassigned,
            selectedScopeSummary: selected
        )
    }

    /// Returns cards due for review at `now`, hydrated with item and template data.
    public func fetchDueCards(
        scope: DeckScope = .allDecks,
        asOf now: Date = .now,
        limit: Int? = nil
    ) async throws -> [DueCard] {
        let studyDay = try await studyDayKey(asOf: now)
        let cards: [Card]
        switch scope {
        case .allDecks:
            cards = try await database.fetchDueCards(asOf: now, studyDay: studyDay, limit: limit)
        case .unassigned:
            cards = try await database.fetchUnassignedDueCards(asOf: now, limit: limit)
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let tree = try await deckTreeSummaries()
                let deckIDs = DeckTree.descendantIDs(of: deckID, in: tree)
                cards = try await database.fetchDueCards(
                    deckIDs: deckIDs,
                    asOf: now,
                    studyDay: studyDay,
                    limit: limit
                )
            } else {
                cards = try await database.fetchDueCards(
                    deckIDs: [deckID],
                    asOf: now,
                    studyDay: studyDay,
                    limit: limit
                )
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

    public func validateItem(_ item: Item) async throws {
        guard let itemType = try await database.fetchItemType(id: item.itemTypeID) else {
            throw DatabaseError.itemTypeNotFound(item.itemTypeID)
        }
        if let deckID = item.deckID,
           try await database.fetchDeck(id: deckID) == nil {
            throw DatabaseError.deckNotFound(deckID)
        }
        _ = try normalizedTags(item.tags)
        try validate(item, against: itemType)
    }

    @discardableResult
    public func renameTag(from source: String, to destination: String, now: Date = .now) async throws -> Int {
        let source = try normalizedTag(source)
        let destination = try normalizedTag(destination)
        let records = try await database.fetchItems()
        let updates: [(UUID, [String])] = records.compactMap { record in
            guard record.item.tags.contains(source) else { return nil }
            var seen: Set<String> = []
            let tags = record.item.tags.map { $0 == source ? destination : $0 }
                .filter { seen.insert($0).inserted }
            return (record.item.id, tags)
        }
        try await database.updateItemTags(updates, now: now)
        return updates.count
    }

    @discardableResult
    public func removeTag(_ value: String, now: Date = .now) async throws -> Int {
        let tag = try normalizedTag(value)
        let records = try await database.fetchItems()
        let updates: [(UUID, [String])] = records.compactMap { record in
            guard record.item.tags.contains(tag) else { return nil }
            return (record.item.id, record.item.tags.filter { $0 != tag })
        }
        try await database.updateItemTags(updates, now: now)
        return updates.count
    }

    /// Updates item content and applies media reference deltas atomically.
    @discardableResult
    public func updateItem(_ item: Item, now: Date = .now) async throws -> SavedItemSummary {
        var item = item
        item.tags = try normalizedTags(item.tags)
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
            createdAt: previous.createdAt,
            // Read back rather than derived from `desiredCards`: reconciliation
            // preserves the memory of cards that survived the edit.
            schedule: try await database.fetchItemCardState(itemID: item.id).scheduleSummary
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
        let studyDay = try await studyDayKey(asOf: now)
        switch scope {
        case .allDecks:
            return try await database.countDueCards(asOf: now, studyDay: studyDay)
        case .unassigned:
            return try await database.countUnassignedDueCards(asOf: now)
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let summaries = try await deckSummaries(asOf: now)
                let deckIDs = DeckTree.descendantIDs(of: deckID, in: summaries)
                return try await database.countDueCards(
                    deckIDs: deckIDs,
                    asOf: now,
                    studyDay: studyDay
                )
            }
            return try await database.countDueCards(
                deckID: deckID,
                asOf: now,
                studyDay: studyDay
            )
        }
    }

    public func dueCount(asOf now: Date = .now) async throws -> Int {
        try await dueCount(scope: .allDecks, asOf: now)
    }

    /// Everything the scope home needs in one snapshot, so the sidebar and the
    /// detail pane cannot disagree about how many cards are due.
    public func scopeSummary(
        scope: DeckScope = .allDecks,
        asOf now: Date = .now
    ) async throws -> ScopeSummary {
        let initialToken = try await database.cacheToken()
        if let cached = scopeSummaryCache[scope],
           cached.isValid(token: initialToken, asOf: now) {
            return cached.summary
        }

        let resolved = try await resolveCardScope(scope, asOf: now)
        let studyDay = try await studyDayKey(asOf: now)
        let totals = try await database.cardScheduleTotals(
            scope: resolved,
            asOf: now,
            studyDay: studyDay,
            leechThreshold: ScopeSummary.leechThreshold
        )
        let itemCount = try await database.countItems(scope: resolved)
        let rollover = try await studyDayRolloverMinutes()

        let summary = ScopeSummary(
            itemCount: itemCount,
            cardCount: totals.cardCount,
            dueNow: totals.dueNow,
            newCount: totals.newCount,
            availableNewCount: totals.availableNewCount,
            hiddenNewCount: totals.hiddenNewCount,
            learningCount: totals.learningCount,
            relearningCount: totals.relearningCount,
            reviewCount: totals.reviewCount,
            leechCount: totals.leechCount,
            nextDueAt: totals.nextDueAt,
            nextNewCardsAt: totals.hiddenNewCount > 0
                ? StudyDay.nextRollover(after: now, rolloverMinutes: rollover)
                : nil
        )
        let finalToken = try await database.cacheToken()
        scopeSummaryCache[scope] = CachedScopeSummary(
            token: finalToken,
            summary: summary,
            calculatedAt: now,
            validUntil: summary.nextStudyAt
        )
        return summary
    }

    /// Expands a requested scope into the deck identifiers it actually covers.
    private func resolveCardScope(
        _ scope: DeckScope,
        asOf now: Date = .now
    ) async throws -> CardScope {
        switch scope {
        case .allDecks:
            return .all
        case .unassigned:
            return .unassigned
        case let .deck(deckID, includeDescendants):
            guard includeDescendants else { return .decks([deckID]) }
            let tree = try await deckTreeSummaries()
            return .decks(DeckTree.descendantIDs(of: deckID, in: tree))
        }
    }

    private func fetchCardStates(
        for scope: DeckScope,
        persisted: [PersistedItem]
    ) async throws -> [UUID: ItemCardState] {
        switch scope {
        case .allDecks:
            return try await database.fetchItemCardStates()
        case .unassigned:
            return try await database.fetchItemCardStatesUnassigned()
        case let .deck(deckID, includeDescendants):
            if includeDescendants {
                let tree = try await deckTreeSummaries()
                let deckIDs = DeckTree.descendantIDs(of: deckID, in: tree)
                return try await database.fetchItemCardStates(deckIDs: deckIDs)
            }
            return try await database.fetchItemCardStates(deckIDs: [deckID])
        }
    }

    /// Drops projected rows whose item type no longer decodes or validates.
    /// Only the quarantined types are read, so an intact library skips this.
    private func browsableRows(
        _ rows: [SavedItemSummary]
    ) async throws -> [SavedItemSummary] {
        let corruptions = try await database.fetchItemTypesWithCorruption().corruptions
        guard !corruptions.isEmpty else { return rows }
        let quarantined = Set(corruptions.compactMap { UUID(uuidString: $0.persistedID) })
        guard !quarantined.isEmpty else { return rows }
        return rows.filter { !quarantined.contains($0.itemTypeID) }
    }

    private func validatedItemTypeMap(
        for persisted: [PersistedItem]
    ) async throws -> [UUID: ItemType] {
        let neededIDs = Set(persisted.map(\.item.itemTypeID))
        guard !neededIDs.isEmpty else { return [:] }
        let loaded = try await database.fetchItemTypesWithCorruption()
        var map: [UUID: ItemType] = [:]
        map.reserveCapacity(neededIDs.count)
        for itemType in loaded.itemTypes where neededIDs.contains(itemType.id) {
            map[itemType.id] = itemType
        }
        return map
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
        guard let persistedCard = try await database.fetchCard(id: cardID) else {
            throw DatabaseError.cardNotFound(cardID)
        }
        let prepared = try await prepareSchedulingReview(
            card: persistedCard,
            rating: rating,
            now: now
        )
        let card = prepared.card
        let memoryBefore = prepared.memoryBefore
        let phaseBefore = memoryBefore.phase
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

        let nextMemory = prepared.memoryAfter

        let log = ReviewLog(
            cardID: card.id,
            reviewedAt: now,
            rating: rating,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            phaseBefore: phaseBefore,
            durationMs: durationMs,
            schedulingAudit: prepared.audit
        )
        let introducedDeckID = phaseBefore == .new ? card.deckID : nil
        let introductionStudyDay: String?
        if introducedDeckID != nil {
            let rollover = try await studyDayRolloverMinutes()
            introductionStudyDay = StudyDay.key(
                for: now,
                rolloverMinutes: rollover
            )
        } else {
            introductionStudyDay = nil
        }

        try await database.persistReview(
            cardID: card.id,
            memoryBefore: memoryBefore,
            memoryAfter: nextMemory,
            log: log,
            introducedDeckID: introducedDeckID,
            introductionStudyDay: introductionStudyDay
        )

        return ReviewSubmission(memory: nextMemory, reviewLogID: log.id)
    }

    public func revertReview(reviewLogID: UUID, now: Date = .now) async throws {
        try await database.revertReview(reviewLogID: reviewLogID, revertedAt: now)
    }

    private func validateDeckLimit(_ limit: Int?) throws {
        if let limit, limit < 0 {
            throw DatabaseError.invalidDeck("New cards per day cannot be negative.")
        }
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

    public func card(id: UUID) async throws -> Card {
        guard let card = try await database.fetchCard(id: id) else {
            throw DatabaseError.cardNotFound(id)
        }
        return card
    }

    public func reviewLog(id: UUID) async throws -> ReviewLog {
        guard let log = try await database.fetchReviewLog(id: id) else {
            throw DatabaseError.reviewLogNotFound(id)
        }
        return log
    }

    public func applySynchronizedCard(_ card: Card) async throws {
        try await database.upsertSynchronizedCard(card)
    }

    public func applySynchronizedReview(_ log: ReviewLog) async throws {
        try await database.insertSynchronizedReviewIfMissing(log)
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
        if let result = try await runAutomaticFSRSOptimization(
            minimumObservations: minimumObservations,
            now: now,
            enforceCadence: false
        ) {
            return result
        }
        let observations = max(0, try await database.countActiveReviewLogs() - 1)
        throw FSRSOptimizationError.insufficientData(
            required: max(FSRSOptimizer.defaultMinimumObservations, minimumObservations),
            available: observations
        )
    }

    /// Fits weights only when accumulated history warrants it, and reports
    /// nothing when it does not.
    ///
    /// This is the automatic path: study ends, this runs, and the learner is
    /// never asked to decide when their scheduler should be tuned. The gate is
    /// one `COUNT` against the last attempt, so a session that adds nothing
    /// meaningful costs no fit.
    @discardableResult
    public func optimizeSchedulingIfNeeded(
        schedule: FSRSOptimizationSchedule = FSRSOptimizationSchedule(),
        minimumObservations: Int = FSRSOptimizer.defaultMinimumObservations,
        now: Date = .now
    ) async throws -> FSRSOptimizationResult? {
        _ = schedule // Source-compatible; versioned cadence is policy-owned.
        return try await runAutomaticFSRSOptimization(
            minimumObservations: minimumObservations,
            now: now
        )
    }

    /// What the most recent automatic or explicit fit saw, if any.
    public func lastOptimizationAttempt() async throws -> FSRSOptimizationSchedule.Attempt? {
        guard
            let stored = try await database.metadataValue(forKey: optimizationAttemptMetadataKey),
            let attempt = OptimizationAttemptRecord(stored)
        else {
            return nil
        }
        return FSRSOptimizationSchedule.Attempt(
            reviewLogCount: attempt.reviewLogCount,
            attemptedAt: attempt.attemptedAt
        )
    }

    func recordOptimizationAttempt(reviewLogCount: Int, at now: Date) async throws {
        try await database.setMetadataValue(
            OptimizationAttemptRecord(
                reviewLogCount: reviewLogCount,
                attemptedAt: now
            ).storedValue,
            forKey: optimizationAttemptMetadataKey
        )
    }

    /// Per profile, because each profile fits its own weights.
    private var optimizationAttemptMetadataKey: String {
        "\(Self.optimizationAttemptMetadataPrefix)\(profileID)"
    }

    /// A count and an instant, stored as one metadata value. Two integers do
    /// not earn a table, and the pair is only ever read and written together.
    private struct OptimizationAttemptRecord {
        let reviewLogCount: Int
        let attemptedAt: Date

        init(reviewLogCount: Int, attemptedAt: Date) {
            self.reviewLogCount = reviewLogCount
            self.attemptedAt = attemptedAt
        }

        init?(_ stored: String) {
            let parts = stored.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let count = Int(parts[0]),
                  count >= 0,
                  let seconds = Double(parts[1]),
                  seconds.isFinite
            else {
                return nil
            }
            reviewLogCount = count
            attemptedAt = Date(timeIntervalSince1970: seconds)
        }

        var storedValue: String {
            "\(reviewLogCount):\(attemptedAt.timeIntervalSince1970)"
        }
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
        try await importItemSummaries(
            from: data,
            adapter: adapter,
            itemTypeID: itemTypeID,
            context: context,
            now: now
        ).count
    }

    /// Imports rows and returns the exact browse summaries committed by this
    /// batch, allowing clients to update an existing library view incrementally.
    public func importItemSummaries(
        from data: Data,
        adapter: some ImportAdapter,
        itemTypeID: UUID? = nil,
        context: ImportContext = ImportContext(),
        now: Date = .now
    ) async throws -> [SavedItemSummary] {
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
            // SQLite stores dates as REAL values. Canonicalize the returned
            // summaries through the same Double representation so an
            // incremental row is identical to a later database reload.
            let persistedCreatedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970)
            return entries.map { entry in
                let activeCards = entry.cards.filter { !$0.isSuspended }
                let next = activeCards.min {
                    if $0.memory.due != $1.memory.due {
                        return $0.memory.due < $1.memory.due
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                return SavedItemSummary(
                    id: entry.item.id,
                    itemTypeID: resolvedType.id,
                    itemTypeName: resolvedType.name,
                    title: ItemDisplay.title(for: entry.item, in: resolvedType),
                    subtitle: ItemDisplay.subtitle(for: entry.item, in: resolvedType),
                    cardCount: entry.cards.count,
                    deckID: entry.item.deckID,
                    createdAt: persistedCreatedAt,
                    schedule: ItemScheduleSummary(
                        dueAt: next.map {
                            Date(timeIntervalSince1970: $0.memory.due.timeIntervalSince1970)
                        },
                        phase: next?.memory.phase,
                        lapses: activeCards.map(\.memory.lapses).max() ?? 0
                    )
                )
            }.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        } catch {
            try? await mediaStore?.rollbackReservations(scopeID: importScope)
            throw error
        }
    }

    func newMediaDescriptors(
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

    private func summaries(
        for persisted: [PersistedItem],
        cardStates: [UUID: ItemCardState]
    ) async throws -> [SavedItemSummary] {
        var summaries: [SavedItemSummary] = []
        summaries.reserveCapacity(persisted.count)
        let itemTypes = try await validatedItemTypeMap(for: persisted)

        for entry in persisted {
            // Malformed definitions are reported by loadItemTypes(), where
            // callers receive the persisted ID and the archive-before-repair
            // path. Keep unrelated item rows usable in the meantime.
            guard let itemType = itemTypes[entry.item.itemTypeID] else { continue }
            let cardState = cardStates[entry.item.id] ?? ItemCardState()
            summaries.append(
                SavedItemSummary(
                    id: entry.item.id,
                    itemTypeID: itemType.id,
                    itemTypeName: itemType.name,
                    title: ItemDisplay.title(for: entry.item, in: itemType),
                    subtitle: ItemDisplay.subtitle(for: entry.item, in: itemType),
                    cardCount: cardState.cardCount,
                    deckID: entry.item.deckID,
                    createdAt: entry.createdAt,
                    schedule: cardState.scheduleSummary
                )
            )
        }
        return summaries
    }

    func hydrateDueCards(_ cards: [Card]) async throws -> [DueCard] {
        guard !cards.isEmpty else { return [] }

        let loadedItemTypes = try await database.fetchItemTypesWithCorruption()
        let itemTypesByID = Dictionary(
            uniqueKeysWithValues: loadedItemTypes.itemTypes.map { ($0.id, $0) }
        )
        var dueCards: [DueCard] = []
        dueCards.reserveCapacity(cards.count)

        // Keep hydration's transient item map bounded as the result grows.
        // Iterating card slices in order preserves the scheduler's exact queue.
        let chunkSize = 500
        var start = 0
        while start < cards.count {
            let end = min(start + chunkSize, cards.count)
            let cardChunk = cards[start..<end]
            start = end
            let persisted = try await database.fetchItems(
                ids: Set(cardChunk.map(\.itemID))
            )
            let itemsByID = Dictionary(
                uniqueKeysWithValues: persisted.map { ($0.item.id, $0.item) }
            )

            for card in cardChunk {
                guard let item = itemsByID[card.itemID] else { continue }
                // The linked card remains persisted and becomes available again
                // after repairItemTypeDefinition archives and repairs its type.
                guard let itemType = itemTypesByID[item.itemTypeID],
                      let template = itemType.templates.first(where: {
                          $0.id == card.templateID
                      })
                else { continue }

                dueCards.append(
                    DueCard(
                        card: card,
                        item: item,
                        itemType: itemType,
                        template: template
                    )
                )
            }
        }

        return dueCards
    }

    func validate(_ item: Item, against itemType: ItemType) throws {
        let definitions = Dictionary(uniqueKeysWithValues: itemType.fields.map { ($0.id, $0) })
        var seen: Set<UUID> = []
        for fieldValue in item.fields {
            guard seen.insert(fieldValue.fieldID).inserted else {
                throw DatabaseError.invalidItem("An item cannot contain the same field twice.")
            }
            guard let definition = definitions[fieldValue.fieldID] else {
                throw DatabaseError.invalidItem("The item contains an unknown field.")
            }
            guard value(fieldValue.value, matches: definition.type) else {
                throw DatabaseError.invalidItem(
                    "The value for \(definition.name) does not match its field type."
                )
            }
            switch fieldValue.value {
            case let .cloze(text, blanks):
                try ClozeValidation.validate(text: text, blanks: blanks)
            case let .media(ref):
                guard ref.isValidStoredReference else {
                    throw MediaError.sandboxViolation
                }
            case let .number(number):
                guard number.isFinite else {
                    throw DatabaseError.invalidItem("Number fields must be finite.")
                }
            case let .rich(spans):
                guard spans.allSatisfy({ $0.link.map(RichTextValidation.isValidLink) ?? true }) else {
                    throw DatabaseError.invalidItem("Rich-text links must use a safe portable URL.")
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

    private func value(_ value: ContentValue, matches type: FieldType) -> Bool {
        if case .empty = value { return true }
        return switch (type, value) {
        case (.text, .text), (.text, .rich), (.richText, .text), (.richText, .rich),
             (.audio, .media),
             (.image, .media), (.gif, .media), (.video, .media),
             (.number, .number), (.cloze, .cloze):
            true
        default:
            false
        }
    }

    func normalizedTags(_ tags: [String]) throws -> [String] {
        guard tags.count <= 256 else {
            throw DatabaseError.invalidItem("An item may contain at most 256 tags.")
        }
        var seen: Set<String> = []
        var result: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !tag.isEmpty, tag.utf8.count <= 1_024 else {
                throw DatabaseError.invalidItem("Tags must be 1 to 1024 UTF-8 bytes.")
            }
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    /// Applies the same identity rules used by item writes to a lookup key.
    public func normalizedTagForLookup(_ raw: String) throws -> String {
        try normalizedTag(raw)
    }

    private func normalizedTag(_ raw: String) throws -> String {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !tag.isEmpty, tag.utf8.count <= 1_024 else {
            throw DatabaseError.invalidItem("Tags must be 1 to 1024 UTF-8 bytes.")
        }
        return tag
    }

}

private func deckPath(for deckID: UUID, decksByID: [UUID: Deck]) -> String {
    var names: [String] = []
    var currentID: UUID? = deckID
    var visited: Set<UUID> = []
    while let candidateID = currentID,
          visited.insert(candidateID).inserted,
          let deck = decksByID[candidateID] {
        names.append(deck.name)
        currentID = deck.parentID
    }
    return names.reversed().joined(separator: " / ")
}
