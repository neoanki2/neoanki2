import Foundation

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

/// Persistence for items and generated cards.
public actor ItemStore {
    private let database: SQLiteDatabase
    private let scheduler: any Scheduler

    public init(databaseURL: URL, scheduler: any Scheduler = FSRSScheduler()) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: databaseURL)
        self.scheduler = scheduler
    }

    /// Opens the database, runs migrations, and seeds built-in item types.
    public func bootstrap() async throws {
        try await database.migrate()
        try await database.seedBuiltInItemTypesIfNeeded()
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

    public func countItems(itemTypeID: UUID) async throws -> Int {
        try await database.countItems(itemTypeID: itemTypeID)
    }

    /// Deletes an item type when it is not built-in and has no items.
    @discardableResult
    public func deleteItemType(id: UUID) async throws -> Bool {
        guard try await database.fetchItemType(id: id) != nil else { return false }
        if BuiltInItemTypes.isBuiltIn(id) {
            throw DatabaseError.invalidItemType("Built-in item types can't be deleted.")
        }
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
        try await database.updateItemType(itemType)

        if let previous {
            try await syncCards(from: previous, to: itemType, now: now)
        }

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

    /// Deletes a deck, reparents subdecks, and moves items to the parent deck or unassigned.
    @discardableResult
    public func deleteDeck(id: UUID) async throws -> Bool {
        guard let deck = try await database.fetchDeck(id: id) else { return false }

        let reassignTo = deck.parentID

        try await database.deleteDeckMovingContents(id: id, reassignTo: reassignTo)

        return true
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

        try await database.insertItemWithCards(item, cards: cards, createdAt: now, updatedAt: now)

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

    /// Deletes an item and its generated cards.
    @discardableResult
    public func deleteItem(id: UUID) async throws -> Bool {
        guard try await database.fetchItem(id: id) != nil else { return false }
        try await database.deleteItem(id: id)
        return true
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
        guard var card = try await database.fetchCard(id: cardID) else {
            throw DatabaseError.cardNotFound(cardID)
        }

        let phaseBefore = card.memory.phase
        let elapsedDays: Double
        if let lastReview = card.memory.lastReview {
            elapsedDays = now.timeIntervalSince(lastReview) / 86_400
        } else {
            elapsedDays = 0
        }

        let scheduledDays = max(
            card.memory.lastReview.map { card.memory.due.timeIntervalSince($0) / 86_400 } ?? 0,
            0
        )

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

        try await database.persistReview(cardID: card.id, memory: nextMemory, log: log)

        return nextMemory
    }

    public func reviewLogCount(for cardID: UUID) async throws -> Int {
        try await database.countReviewLogs(for: cardID)
    }

    /// Imports rows parsed by a native adapter into an existing item type.
    @discardableResult
    public func importItems(
        from data: Data,
        adapter: some ImportAdapter,
        itemTypeID: UUID? = nil,
        now: Date = .now
    ) async throws -> Int {
        let payload = try adapter.parse(data)
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

        var importedCount = 0
        for row in payload.rows {
            let fields = try mapImportRow(row, to: resolvedType)
            let item = Item(itemTypeID: resolvedType.id, fields: fields, tags: row.tags)
            _ = try await createItem(item, now: now)
            importedCount += 1
        }

        return importedCount
    }

    private func mapImportRow(_ row: ImportRow, to itemType: ItemType) throws -> [FieldValue] {
        var values: [FieldValue] = []

        for field in itemType.fields {
            guard let text = row.fieldValues[field.name] else {
                if field.isRequired {
                    throw DatabaseError.requiredFieldEmpty(field.name)
                }
                continue
            }

            values.append(FieldValue(fieldID: field.id, value: field.contentValue(from: text)))
        }

        for key in row.fieldValues.keys where itemType.field(named: key) == nil {
            throw ImportError.unknownField(key)
        }

        return values
    }

    private func summaries(for persisted: [PersistedItem]) async throws -> [SavedItemSummary] {
        var summaries: [SavedItemSummary] = []
        summaries.reserveCapacity(persisted.count)

        for entry in persisted {
            guard let itemType = try await database.fetchItemType(id: entry.item.itemTypeID) else {
                continue
            }
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
            guard
                let persisted = try await database.fetchItem(id: card.itemID),
                let itemType = try await database.fetchItemType(id: persisted.item.itemTypeID),
                let template = itemType.templates.first(where: { $0.id == card.templateID })
            else {
                continue
            }

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
        for field in itemType.fields where field.isRequired {
            guard let value = item.value(for: field.id), !value.isEmpty else {
                throw DatabaseError.requiredFieldEmpty(field.name)
            }
        }
    }

    private func syncCards(from previous: ItemType, to updated: ItemType, now: Date) async throws {
        let previousTemplateIDs = Set(previous.templates.map(\.id))
        let updatedTemplateIDs = Set(updated.templates.map(\.id))

        let added = updatedTemplateIDs.subtracting(previousTemplateIDs)
        let removed = previousTemplateIDs.subtracting(updatedTemplateIDs)
        let kept = previousTemplateIDs.intersection(updatedTemplateIDs)

        let items = try await database.fetchItems(itemTypeID: updated.id)

        for entry in items {
            let item = entry.item

            for templateID in removed {
                try await database.deleteCards(itemID: item.id, templateID: templateID)
            }

            let existingCards = try await database.fetchCards(for: item.id)
            let existingTemplateIDs = Set(existingCards.map(\.templateID))

            for template in updated.templates where added.contains(template.id) {
                guard CardGenerator.shouldGenerate(template, for: item) else { continue }
                guard !existingTemplateIDs.contains(template.id) else { continue }

                let card = Card(
                    itemID: item.id,
                    templateID: template.id,
                    skill: template.skill,
                    memory: .new(due: now),
                    deckID: item.deckID
                )
                try await database.insertCards([card])
            }

            for template in updated.templates where kept.contains(template.id) {
                guard
                    let previousTemplate = previous.templates.first(where: { $0.id == template.id }),
                    previousTemplate.skill != template.skill
                else {
                    continue
                }

                for card in existingCards where card.templateID == template.id {
                    try await database.updateCardSkill(card.id, skill: template.skill)
                }
            }
        }
    }
}
