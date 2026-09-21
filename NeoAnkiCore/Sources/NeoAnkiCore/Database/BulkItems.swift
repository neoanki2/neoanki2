import Foundation

public enum ItemBulkAction: Sendable, Equatable {
    case create(Item)
    case replace(Item)
    case delete(UUID)
}

public struct ItemBulkOperation: Sendable, Equatable {
    public let operationID: String
    public let action: ItemBulkAction

    public init(operationID: String, action: ItemBulkAction) {
        self.operationID = operationID
        self.action = action
    }
}

public struct ItemBulkOperationResult: Sendable, Equatable {
    public let operationID: String
    public let action: String
    public let itemID: UUID
    public let cardIDs: [UUID]

    public init(operationID: String, action: String, itemID: UUID, cardIDs: [UUID]) {
        self.operationID = operationID
        self.action = action
        self.itemID = itemID
        self.cardIDs = cardIDs
    }
}

public struct ItemBulkOperationError: Error, Sendable, Equatable, LocalizedError {
    public let operationID: String
    public let pointer: String
    public let detail: String

    public var errorDescription: String? { detail }
}

enum ItemBulkDatabaseMutation: Sendable {
    case create(
        item: Item,
        cards: [Card],
        descriptors: [String: MediaAssetDescriptor],
        createdAt: Date
    )
    case replace(
        item: Item,
        cards: [Card],
        descriptors: [String: MediaAssetDescriptor],
        updatedAt: Date
    )
    case delete(id: UUID, deletedAt: Date)
}

private struct BulkCardIdentity: Hashable {
    let templateID: UUID
    let clozeGroup: Int?
}

public extension ItemStore {
    /// Reconciles a compatible item-type extension and its affected items in
    /// one revision-tracked transaction. This is intentionally narrower than
    /// Item Type Studio: existing fields and card-template identities must be
    /// preserved so learned cards keep their schedules and review histories.
    func reconcileItemTypeAndItems(
        expectedItemType: ItemType,
        updatedItemType: ItemType,
        replacements: [Item],
        now: Date = .now
    ) async throws -> [ItemBulkOperationResult] {
        guard expectedItemType.id == updatedItemType.id else {
            throw DatabaseError.invalidItemType("The reconciled item type identity changed.")
        }
        guard !replacements.isEmpty, replacements.count <= 500 else {
            throw DatabaseError.invalidItem("A reconciliation must contain between 1 and 500 items.")
        }
        try ItemTypeValidation.validate(updatedItemType)

        let updatedFields = Dictionary(
            uniqueKeysWithValues: updatedItemType.fields.map { ($0.id, $0) }
        )
        guard expectedItemType.fields.allSatisfy({ updatedFields[$0.id] == $0 }) else {
            throw DatabaseError.invalidItemType(
                "Reconciliation may add optional fields but cannot change or remove existing fields."
            )
        }
        let addedFields = updatedItemType.fields.filter { field in
            !expectedItemType.fields.contains { $0.id == field.id }
        }
        guard addedFields.allSatisfy({ !$0.isRequired }) else {
            throw DatabaseError.invalidItemType("Reconciliation may add only optional fields.")
        }
        guard expectedItemType.templates.map(\.id) == updatedItemType.templates.map(\.id) else {
            throw DatabaseError.invalidItemType(
                "Reconciliation cannot add, remove, or reorder card templates."
            )
        }
        let addedFieldIDs = Set(addedFields.map(\.id))
        for (expected, updated) in zip(expectedItemType.templates, updatedItemType.templates) {
            guard expected.name == updated.name,
                  expected.layout == updated.layout,
                  expected.interaction == updated.interaction,
                  expected.skill == updated.skill,
                  expected.generateWhen == updated.generateWhen
            else {
                throw DatabaseError.invalidItemType(
                    "Reconciliation cannot change existing card-template behavior."
                )
            }
            let expectedComponentIDs = Set(expected.components.map(\.id))
            guard updated.components.filter({ expectedComponentIDs.contains($0.id) })
                == expected.components
            else {
                throw DatabaseError.invalidItemType(
                    "Reconciliation cannot change or reorder existing card components."
                )
            }
            let additions = updated.components.filter { !expectedComponentIDs.contains($0.id) }
            guard additions.allSatisfy({ component in
                guard component.purpose == .expectedAnswer,
                      component.presentation.reveal == .hiddenUntilAnswer,
                      case let .field(fieldID) = component.source
                else { return false }
                return addedFieldIDs.contains(fieldID)
            }) else {
                throw DatabaseError.invalidItemType(
                    "New reconciliation fields must be revealed only with the expected answer."
                )
            }
        }

        var seen: Set<UUID> = []
        var mutations: [ItemBulkDatabaseMutation] = []
        var results: [ItemBulkOperationResult] = []
        for (index, source) in replacements.enumerated() {
            guard source.itemTypeID == expectedItemType.id,
                  seen.insert(source.id).inserted
            else {
                throw DatabaseError.invalidItem(
                    "Every replacement must be unique and retain the reconciled item type."
                )
            }
            guard let previous = try await database.fetchItem(id: source.id) else {
                throw DatabaseError.itemNotFound(source.id)
            }
            let planned = try await planBulkItem(
                source,
                previous: previous.item,
                itemType: updatedItemType,
                now: now
            )
            let existing = try await database.fetchCards(for: source.id)
            let existingByIdentity = Dictionary(
                existing.map {
                    (BulkCardIdentity(templateID: $0.templateID, clozeGroup: $0.clozeGroup), $0)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let finalCardIDs = planned.cards.map { card in
                existingByIdentity[
                    BulkCardIdentity(templateID: card.templateID, clozeGroup: card.clozeGroup)
                ]?.id ?? card.id
            }
            mutations.append(.replace(
                item: planned.item,
                cards: planned.cards,
                descriptors: planned.descriptors,
                updatedAt: now
            ))
            results.append(.init(
                operationID: "reconcile-\(index)",
                action: "replace",
                itemID: source.id,
                cardIDs: finalCardIDs
            ))
        }

        try await database.applyItemTypeAndItemReconciliation(
            expectedOriginal: expectedItemType,
            updated: updatedItemType,
            mutations: mutations,
            now: now
        )
        for cardID in results.flatMap(\.cardIDs) {
            _ = try await database.ensureSchedulerCardHistory(cardID: cardID, now: now)
        }
        return results
    }

    /// Fully plans the batch before opening its single write transaction. This
    /// makes validation, media lookup, and generated-card planning identical
    /// for dry runs and commits and prevents a late member failure from
    /// producing partial domain state.
    func executeItemBulk(
        _ operations: [ItemBulkOperation],
        dryRun: Bool,
        now: Date = .now
    ) async throws -> [ItemBulkOperationResult] {
        guard !operations.isEmpty, operations.count <= 500 else {
            throw DatabaseError.invalidItem("A bulk request must contain between 1 and 500 operations.")
        }

        var operationIDs: Set<String> = []
        var itemIDs: Set<UUID> = []
        for operation in operations {
            guard !operation.operationID.isEmpty,
                  operation.operationID.utf8.count <= 256,
                  operationIDs.insert(operation.operationID).inserted
            else {
                throw DatabaseError.invalidItem("Bulk operation IDs must be unique and 1 to 256 UTF-8 bytes.")
            }
            let itemID: UUID
            switch operation.action {
            case let .create(item), let .replace(item): itemID = item.id
            case let .delete(id): itemID = id
            }
            guard itemIDs.insert(itemID).inserted else {
                throw DatabaseError.invalidItem("A bulk request may address each item ID only once.")
            }
        }

        var mutations: [ItemBulkDatabaseMutation] = []
        var results: [ItemBulkOperationResult] = []
        mutations.reserveCapacity(operations.count)
        results.reserveCapacity(operations.count)

        for (index, operation) in operations.enumerated() {
            do {
                switch operation.action {
                case let .create(source):
                    guard try await database.fetchItem(id: source.id) == nil else {
                        throw DatabaseError.invalidItem("The item ID already exists.")
                    }
                    let planned = try await planBulkItem(source, previous: nil, now: now)
                    mutations.append(.create(
                        item: planned.item,
                        cards: planned.cards,
                        descriptors: planned.descriptors,
                        createdAt: now
                    ))
                    results.append(.init(
                        operationID: operation.operationID,
                        action: "create",
                        itemID: planned.item.id,
                        cardIDs: planned.cards.map(\.id)
                    ))

                case let .replace(source):
                    guard let previous = try await database.fetchItem(id: source.id) else {
                        throw DatabaseError.itemNotFound(source.id)
                    }
                    guard previous.item.itemTypeID == source.itemTypeID else {
                        throw DatabaseError.invalidItem("itemTypeID is immutable after creation.")
                    }
                    let planned = try await planBulkItem(source, previous: previous.item, now: now)
                    let existing = try await database.fetchCards(for: source.id)
                    let existingByIdentity = Dictionary(
                        existing.map {
                            (BulkCardIdentity(templateID: $0.templateID, clozeGroup: $0.clozeGroup), $0)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let finalCardIDs = planned.cards.map { card in
                        existingByIdentity[
                            BulkCardIdentity(templateID: card.templateID, clozeGroup: card.clozeGroup)
                        ]?.id ?? card.id
                    }
                    mutations.append(.replace(
                        item: planned.item,
                        cards: planned.cards,
                        descriptors: planned.descriptors,
                        updatedAt: now
                    ))
                    results.append(.init(
                        operationID: operation.operationID,
                        action: "replace",
                        itemID: planned.item.id,
                        cardIDs: finalCardIDs
                    ))

                case let .delete(id):
                    guard try await database.fetchItem(id: id) != nil else {
                        throw DatabaseError.itemNotFound(id)
                    }
                    mutations.append(.delete(id: id, deletedAt: now))
                    results.append(.init(
                        operationID: operation.operationID,
                        action: "delete",
                        itemID: id,
                        cardIDs: []
                    ))
                }
            } catch {
                throw ItemBulkOperationError(
                    operationID: operation.operationID,
                    pointer: "/operations/\(index)",
                    detail: error.localizedDescription
                )
            }
        }

        if !dryRun {
            try await database.applyItemBulk(mutations)
        }
        return results
    }

    private func planBulkItem(
        _ source: Item,
        previous: Item?,
        itemType itemTypeOverride: ItemType? = nil,
        now: Date
    ) async throws -> (
        item: Item,
        cards: [Card],
        descriptors: [String: MediaAssetDescriptor]
    ) {
        let item = Item(
            id: source.id,
            itemTypeID: source.itemTypeID,
            fields: source.fields,
            tags: try normalizedTags(source.tags),
            deckID: source.deckID
        )
        let itemType: ItemType
        if let itemTypeOverride {
            guard itemTypeOverride.id == item.itemTypeID else {
                throw DatabaseError.itemTypeNotFound(item.itemTypeID)
            }
            itemType = itemTypeOverride
        } else {
            guard let stored = try await database.fetchItemType(id: item.itemTypeID) else {
                throw DatabaseError.itemTypeNotFound(item.itemTypeID)
            }
            itemType = stored
        }
        if let deckID = item.deckID,
           try await database.fetchDeck(id: deckID) == nil {
            throw DatabaseError.deckNotFound(deckID)
        }
        try validate(item, against: itemType)
        return (
            item,
            CardGenerator.cards(
                for: item,
                type: itemType,
                now: now,
                deterministicIDs: true
            ),
            try await newMediaDescriptors(in: item, comparedTo: previous)
        )
    }
}
