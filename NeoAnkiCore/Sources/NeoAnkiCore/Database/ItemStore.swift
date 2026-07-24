import Foundation

/// An item loaded from persistence with summary fields for list display.
public struct SavedItemSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let itemTypeID: UUID
    public let itemTypeName: String
    public let title: String
    public let subtitle: String
    public let cardCount: Int
    public let createdAt: Date

    public init(
        id: UUID,
        itemTypeID: UUID,
        itemTypeName: String,
        title: String,
        subtitle: String,
        cardCount: Int,
        createdAt: Date
    ) {
        self.id = id
        self.itemTypeID = itemTypeID
        self.itemTypeName = itemTypeName
        self.title = title
        self.subtitle = subtitle
        self.cardCount = cardCount
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
        try await database.insertItemType(itemType)
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

    /// Saves an item and the cards generated from its item type templates.
    @discardableResult
    public func createItem(_ item: Item, now: Date = .now) async throws -> SavedItemSummary {
        guard let itemType = try await database.fetchItemType(id: item.itemTypeID) else {
            throw DatabaseError.itemTypeNotFound(item.itemTypeID)
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
            createdAt: now
        )
    }

    public func listItems() async throws -> [SavedItemSummary] {
        let persisted = try await database.fetchItems()
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
                    createdAt: entry.createdAt
                )
            )
        }
        return summaries
    }

    /// Returns cards due for review at `now`, hydrated with item and template data.
    public func fetchDueCards(asOf now: Date = .now, limit: Int? = nil) async throws -> [DueCard] {
        let cards = try await database.fetchDueCards(asOf: now, limit: limit)
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

    public func dueCount(asOf now: Date = .now) async throws -> Int {
        try await database.countDueCards(asOf: now)
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

    private func validate(_ item: Item, against itemType: ItemType) throws {
        for field in itemType.fields where field.isRequired {
            guard let value = item.value(for: field.id), !value.isEmpty else {
                throw DatabaseError.requiredFieldEmpty(field.name)
            }
        }
    }
}
