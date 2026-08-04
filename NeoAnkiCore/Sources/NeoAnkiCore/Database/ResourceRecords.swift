import Foundation

public struct LibraryItemRecord: Sendable, Equatable, Identifiable {
    public let item: Item
    public let createdAt: Date
    public let updatedAt: Date
    public let cardIDs: [UUID]

    public var id: UUID { item.id }

    public init(item: Item, createdAt: Date, updatedAt: Date, cardIDs: [UUID]) {
        self.item = item
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cardIDs = cardIDs
    }
}

public struct ReservedMediaAsset: Sendable, Equatable {
    public let reference: MediaRef
    public let reservationID: UUID
    public let reservationExpiresAt: Date
    public let byteSize: Int
}

public enum DeckDeletionPolicy: String, Codable, Sendable, Equatable {
    case rejectIfNonempty
    case unassignItems
    case moveItemsToParent
    case deleteSubtreeAndItems
}

public struct DeckDeletionImpact: Codable, Sendable, Equatable {
    public let deckCount: Int
    public let itemCount: Int
    public let cardCount: Int
    public let reviewLogCount: Int
    public let mediaReferenceCount: Int
}

public struct DeckResetImpact: Codable, Sendable, Equatable {
    public let deckCount: Int
    public let cardCount: Int
    public let reviewLogCount: Int
}

public extension ItemStore {
    func deckDeletionImpact(
        id: UUID,
        policy: DeckDeletionPolicy
    ) async throws -> DeckDeletionImpact {
        let deck = try await deck(id: id)
        _ = deck
        let descendants = DeckTree.descendantIDs(of: id, in: try await deckSummaries())
        let items = try await itemRecords().filter { record in
            record.item.deckID.map(descendants.contains) ?? false
        }
        let itemIDs = Set(items.map(\.id))
        let cards = try await cards().filter { itemIDs.contains($0.itemID) }
        var reviewCount = 0
        for card in cards {
            reviewCount += try await database.countRawReviewLogs(for: card.id)
        }
        let mediaCount = items.reduce(0) { total, record in
            total + record.item.fields.count { field in
                if case .media = field.value { true } else { false }
            }
        }
        return DeckDeletionImpact(
            deckCount: descendants.count,
            itemCount: items.count,
            cardCount: cards.count,
            reviewLogCount: reviewCount,
            mediaReferenceCount: mediaCount
        )
    }

    func commitDeckDeletion(id: UUID, policy: DeckDeletionPolicy, now: Date = .now) async throws {
        let deck = try await deck(id: id)
        let descendants = DeckTree.descendantIDs(of: id, in: try await deckSummaries())
        try await database.applyDeckDeletion(
            rootID: id,
            descendantIDs: descendants,
            parentID: deck.parentID,
            policy: policy,
            deletedAt: now
        )
    }

    func deckResetImpact(id: UUID) async throws -> DeckResetImpact {
        _ = try await deck(id: id)
        let descendants = DeckTree.descendantIDs(of: id, in: try await deckSummaries())
        let cards = try await cards().filter { card in
            card.deckID.map(descendants.contains) ?? false
        }
        var reviewCount = 0
        for card in cards {
            reviewCount += try await database.countRawReviewLogs(for: card.id)
        }
        return DeckResetImpact(
            deckCount: descendants.count,
            cardCount: cards.count,
            reviewLogCount: reviewCount
        )
    }

    func reserveMedia(
        data: Data,
        kind: MediaKind,
        altText: String? = nil,
        reservationID: UUID = UUID(),
        now: Date = .now
    ) async throws -> ReservedMediaAsset {
        guard let mediaStore else {
            throw DatabaseError.invalidMediaAsset("Media storage is unavailable.")
        }
        let scopeID = UUID()
        let reference = try await mediaStore.ingest(
            data: data,
            kind: kind,
            altText: altText,
            reservationID: reservationID,
            reservationScope: scopeID
        )
        guard let reservationID = reference.reservationID else {
            throw DatabaseError.invalidMediaAsset("Media reservation was not created.")
        }
        return ReservedMediaAsset(
            reference: reference,
            reservationID: reservationID,
            reservationExpiresAt: try await database.mediaReservationExpiresAt(
                id: reservationID
            ) ?? now.addingTimeInterval(24 * 60 * 60),
            byteSize: data.count
        )
    }

    func mediaBytes(hash: String) async throws -> (MediaAsset, Data) {
        guard let asset = try await database.fetchMediaAsset(hash: hash),
              let mediaStore
        else { throw DatabaseError.invalidMediaAsset("The media asset does not exist.") }
        let ref = MediaRef(
            kind: asset.kind,
            assetHash: asset.hash,
            fileExtension: asset.fileExtension
        )
        let url = try await mediaStore.resolve(ref)
        return (asset, try Data(contentsOf: url))
    }
    func itemRecord(id: UUID) async throws -> LibraryItemRecord {
        guard let persisted = try await database.fetchItem(id: id) else {
            throw DatabaseError.itemNotFound(id)
        }
        let cards = try await database.fetchCards(for: id)
        return LibraryItemRecord(
            item: persisted.item,
            createdAt: persisted.createdAt,
            updatedAt: persisted.updatedAt,
            cardIDs: cards.map(\.id).sorted { $0.uuidString < $1.uuidString }
        )
    }

    func itemRecords() async throws -> [LibraryItemRecord] {
        let persisted = try await database.fetchItems()
        var result: [LibraryItemRecord] = []
        result.reserveCapacity(persisted.count)
        for entry in persisted {
            let cards = try await database.fetchCards(for: entry.item.id)
            result.append(LibraryItemRecord(
                item: entry.item,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                cardIDs: cards.map(\.id).sorted { $0.uuidString < $1.uuidString }
            ))
        }
        return result
    }

    func itemRecordsPage(offset: Int, limit: Int) async throws -> [LibraryItemRecord] {
        let persisted = try await database.fetchItemsPage(offset: offset, limit: limit)
        var result: [LibraryItemRecord] = []
        result.reserveCapacity(persisted.count)
        for entry in persisted {
            let cards = try await database.fetchCards(for: entry.item.id)
            result.append(LibraryItemRecord(
                item: entry.item,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                cardIDs: cards.map(\.id).sorted { $0.uuidString < $1.uuidString }
            ))
        }
        return result
    }

    func cards() async throws -> [Card] {
        try await database.fetchAllCards()
    }

    func hydratedCard(id: UUID) async throws -> DueCard {
        let card = try await card(id: id)
        guard let item = try await database.fetchItem(id: card.itemID)?.item,
              let itemType = try await database.fetchItemType(id: item.itemTypeID),
              let template = itemType.templates.first(where: { $0.id == card.templateID })
        else {
            throw DatabaseError.cardNotFound(id)
        }
        return DueCard(card: card, item: item, itemType: itemType, template: template)
    }

    func reviewPreviews(cardID: UUID, now: Date = .now) async throws -> [ReviewRating: MemoryState] {
        let card = try await card(id: cardID)
        let scheduler: any Scheduler = schedulerOverride
            ?? LearningScheduler(parameters: fsrsParameters)
        return Dictionary(uniqueKeysWithValues: ReviewRating.allCases.map {
            ($0, scheduler.schedule(card.memory, rating: $0, now: now))
        })
    }

    @discardableResult
    func setCardSuspended(id: UUID, isSuspended: Bool) async throws -> Card {
        try await database.setCardSuspended(id: id, isSuspended: isSuspended)
        return try await card(id: id)
    }

    @discardableResult
    func resetCardProgress(id: UUID, now: Date = .now) async throws -> Card {
        try await database.resetCardProgress(id: id, now: now)
        return try await card(id: id)
    }
}
