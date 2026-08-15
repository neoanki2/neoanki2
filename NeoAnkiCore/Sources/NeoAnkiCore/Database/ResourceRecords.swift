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
    public let studyResponseCount: Int

    public init(
        deckCount: Int,
        itemCount: Int,
        cardCount: Int,
        reviewLogCount: Int,
        mediaReferenceCount: Int,
        studyResponseCount: Int = 0
    ) {
        self.deckCount = deckCount
        self.itemCount = itemCount
        self.cardCount = cardCount
        self.reviewLogCount = reviewLogCount
        self.mediaReferenceCount = mediaReferenceCount
        self.studyResponseCount = studyResponseCount
    }
}

public struct DeckResetImpact: Codable, Sendable, Equatable {
    public let deckCount: Int
    public let cardCount: Int
    public let reviewLogCount: Int
}

public struct SynchronizedReviewRecord: Codable, Sendable, Equatable {
    public let log: ReviewLog
    public let memoryBefore: MemoryState

    public init(log: ReviewLog, memoryBefore: MemoryState) {
        self.log = log
        self.memoryBefore = memoryBefore
    }
}

public struct SynchronizedItemRecord: Codable, Sendable, Equatable {
    public let item: Item
    public let createdAt: Date
    public let updatedAt: Date

    public init(item: Item, createdAt: Date, updatedAt: Date) {
        self.item = item
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ReviewRevertRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let reviewLogID: UUID
    public let revertedAt: Date

    public init(id: UUID, reviewLogID: UUID, revertedAt: Date) {
        self.id = id
        self.reviewLogID = reviewLogID
        self.revertedAt = revertedAt
    }
}

public enum ItemTypeMembershipRecord: Codable, Sendable, Equatable, Identifiable {
    case library(itemTypeID: UUID)
    case included(rootDeckID: UUID, itemTypeID: UUID, ordinal: Int)
    case policy(deckID: UUID, itemTypeID: UUID, ordinal: Int, isDefault: Bool)

    public var id: String {
        switch self {
        case let .library(itemTypeID): "library:\(itemTypeID.uuidString)"
        case let .included(rootDeckID, itemTypeID, _):
            "included:\(rootDeckID.uuidString):\(itemTypeID.uuidString)"
        case let .policy(deckID, itemTypeID, _, _):
            "policy:\(deckID.uuidString):\(itemTypeID.uuidString)"
        }
    }
}

public enum SchedulingSettingsRecord: Codable, Sendable, Equatable, Identifiable {
    case studyDayRollover(minutes: Int)
    case scheduler(
        profileID: String,
        parameters: FSRSScheduler.Parameters,
        optimizedAt: Date,
        sampleCount: Int,
        logLoss: Double
    )

    public var id: String {
        switch self {
        case .studyDayRollover: "rollover"
        case let .scheduler(profileID, _, _, _, _): "profile:\(profileID)"
        }
    }
}

public struct PortableItemTypeMappingRecord: Codable, Sendable, Equatable, Identifiable {
    public let originLibraryID: UUID
    public let originTypeID: UUID
    public let schemaDigest: String
    public let localTypeID: UUID

    public var id: String {
        "\(originLibraryID.uuidString):\(originTypeID.uuidString):\(schemaDigest)"
    }

    public init(originLibraryID: UUID, originTypeID: UUID, schemaDigest: String, localTypeID: UUID) {
        self.originLibraryID = originLibraryID
        self.originTypeID = originTypeID
        self.schemaDigest = schemaDigest
        self.localTypeID = localTypeID
    }
}

public enum SynchronizedLibraryMutation: Sendable {
    case deck(Deck)
    case itemType(ItemType)
    case item(Item, createdAt: Date, updatedAt: Date)
    case card(Card)
    case review(SynchronizedReviewRecord)
    case reviewRevert(ReviewRevertRecord)
    case itemTypeMembership(ItemTypeMembershipRecord)
    case schedulingSettings(SchedulingSettingsRecord)
    case portableTypeMapping(PortableItemTypeMappingRecord)
    case tombstone(kind: LibraryResourceKind, id: String)
}

public extension ItemStore {
    func recordLibraryAlias(_ aliasID: UUID, canonicalID: UUID) async throws {
        try await database.recordLibraryAlias(aliasID, canonicalID: canonicalID)
    }

    func libraryAliases(canonicalID: UUID) async throws -> Set<UUID> {
        try await database.fetchLibraryAliases(canonicalID: canonicalID)
    }

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
            mediaReferenceCount: mediaCount,
            studyResponseCount: try await database.countStudyResponses(
                cardIDs: Set(cards.map(\.id))
            )
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

    func synchronizedReviewRecord(id: UUID) async throws -> SynchronizedReviewRecord {
        guard let record = try await database.fetchSynchronizedReviewRecord(id: id) else {
            throw DatabaseError.reviewLogNotFound(id)
        }
        return record
    }

    func synchronizedItemRecord(id: UUID) async throws -> SynchronizedItemRecord {
        let record = try await itemRecord(id: id)
        return SynchronizedItemRecord(
            item: record.item,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    func reviewRevertRecord(id: UUID) async throws -> ReviewRevertRecord {
        guard let record = try await database.fetchReviewRevertRecord(id: id) else {
            throw DatabaseError.reviewLogNotFound(id)
        }
        return record
    }

    func itemTypeMembershipRecord(id: String) async throws -> ItemTypeMembershipRecord {
        guard let record = try await database.fetchItemTypeMembershipRecord(id: id) else {
            throw DatabaseError.queryFailed("Item-type membership no longer exists.")
        }
        return record
    }

    func schedulingSettingsRecord(id: String) async throws -> SchedulingSettingsRecord {
        guard let record = try await database.fetchSchedulingSettingsRecord(id: id) else {
            throw DatabaseError.queryFailed("Scheduling settings no longer exist.")
        }
        return record
    }

    func portableItemTypeMappingRecord(id: String) async throws -> PortableItemTypeMappingRecord {
        guard let record = try await database.fetchPortableItemTypeMappingRecord(id: id) else {
            throw DatabaseError.queryFailed("Portable item-type mapping no longer exists.")
        }
        return record
    }

    func applySynchronizedBatch(_ mutations: [SynchronizedLibraryMutation]) async throws {
        try await database.applySynchronizedBatch(mutations)
        for mutation in mutations {
            if case let .schedulingSettings(.scheduler(profileID, parameters, _, _, _)) = mutation,
               profileID == self.profileID {
                fsrsParameters = parameters
            }
        }
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
        return try await previewSchedulingContext(card: card, now: now)
    }

    func reviewPreviewDetails(
        cardID: UUID,
        now: Date = .now
    ) async throws -> [ReviewRating: ReviewSchedulePreviewDetail] {
        let card = try await card(id: cardID)
        return try await detailedReviewPreviews(card: card, now: now)
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
