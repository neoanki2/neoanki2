import Foundation

public extension ItemStore {
    func defaultItemType() async throws -> ItemType {
        try await itemType(id: BuiltInItemTypes.basicID)
    }

    func itemType(id: UUID) async throws -> ItemType {
        guard let itemType = try await database.fetchItemType(id: id) else {
            throw DatabaseError.itemTypeNotFound(id)
        }
        return itemType
    }

    @discardableResult
    func createItemType(_ itemType: ItemType) async throws -> ItemType {
        try ItemTypeValidation.validate(itemType)
        try await database.createScopedType(itemType, deckID: nil, shared: false)
        return itemType
    }

    func listItemTypes() async throws -> [ItemType] {
        try await database.fetchAllItemTypes()
    }

    func loadItemTypes() async throws -> ItemTypeLoadResult {
        try await database.fetchItemTypesWithCorruption()
    }

    func loadItemTypeCatalog() async throws -> ItemTypeCatalog {
        let result = try await database.fetchItemTypesWithCorruption()
        let settings = Dictionary(uniqueKeysWithValues: try await database.fetchTypeSettings().map { ($0.itemTypeID, $0) })
        let libraryIDs = try await database.fetchLibraryItemTypeIDs()
        let owners = try await database.fetchIncludedItemTypeOwners()
        let decks = try await database.fetchAllDecks()
        let typesByID = Dictionary(uniqueKeysWithValues: result.itemTypes.map { ($0.id, $0) })
        let decksByID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        let shared = result.itemTypes.filter { settings[$0.id]?.isShared ?? BuiltInItemTypes.isBuiltIn($0.id) }
        var groups: [IncludedItemTypeGroup] = []
        var attached: Set<UUID> = []
        for deck in decks {
            guard let policy = try await database.resolvedTypePolicy(deckID: deck.id), policy.sourceDeckID == deck.id else { continue }
            let local = policy.itemTypes
            attached.formUnion(local.map(\.id))
            if !local.isEmpty { groups.append(.init(rootDeck: deck, deckPath: itemStoreDeckPath(for: deck.id, decksByID: decksByID), itemTypes: local)) }
        }
        // Provenance remains discoverable even when an override excludes an imported type.
        for owner in owners where !attached.contains(owner.itemTypeID) {
            guard let deck = decksByID[owner.rootDeckID], let type = typesByID[owner.itemTypeID], !shared.contains(type) else { continue }
            if let index = groups.firstIndex(where: { $0.id == deck.id }) {
                groups[index] = .init(rootDeck: deck, deckPath: groups[index].deckPath, itemTypes: groups[index].itemTypes + [type])
            } else { groups.append(.init(rootDeck: deck, deckPath: itemStoreDeckPath(for: deck.id, decksByID: decksByID), itemTypes: [type])) }
            attached.insert(type.id)
        }
        let protected = Set(result.itemTypes.filter { type in
            !(settings[type.id]?.isEditable ?? (libraryIDs.contains(type.id) || !owners.contains { owner in owner.itemTypeID == type.id }))
        }.map(\.id))
        return .init(itemTypes: shared, includedWithDecks: groups.sorted { $0.deckPath < $1.deckPath }, corruptions: result.corruptions,
            needsOrganization: result.itemTypes.filter { !attached.contains($0.id) && !shared.contains($0) }, readOnlyIDs: protected)
    }

    func effectiveItemTypePolicy(for deckID: UUID) async throws -> DeckItemTypePolicy? {
        try await database.resolvedTypePolicy(deckID: deckID)
    }

    func authoringItemTypes(for deckID: UUID?) async throws -> AuthoringItemTypes {
        let policy: DeckItemTypePolicy?
        if let deckID { policy = try await database.resolvedTypePolicy(deckID: deckID) } else { policy = nil }
        let useShared = policy?.itemTypes.isEmpty != false
        let choices: [ItemType]
        if useShared {
            let settings = Dictionary(uniqueKeysWithValues: try await database.fetchTypeSettings().map { ($0.itemTypeID, $0) })
            choices = try await database.fetchAllItemTypes().filter { settings[$0.id]?.isShared ?? BuiltInItemTypes.isBuiltIn($0.id) }
        } else { choices = policy!.itemTypes }
        let defaultID = useShared ? choices.first { $0.id == BuiltInItemTypes.basicID }?.id : policy?.defaultItemTypeID
        return .init(deckID: deckID, sourceDeckID: policy?.sourceDeckID, itemTypes: choices,
            defaultItemTypeID: defaultID, usesSharedFallback: useShared)
    }

    @discardableResult
    func createItemType(_ type: ItemType, deckID: UUID?, availableEverywhere: Bool) async throws -> ItemType {
        try ItemTypeValidation.validate(type)
        try await database.createScopedType(type, deckID: deckID, shared: availableEverywhere)
        return type
    }

    func attachItemType(id: UUID, to deckID: UUID) async throws { try await database.attachType(id, to: deckID) }
    func setDeckItemTypes(_ settings: DeckItemTypeSettings) async throws { try await database.saveDeckTypeSettings(settings) }
    func setItemTypeAvailability(id: UUID, availableEverywhere: Bool) async throws {
        let catalog = try await loadItemTypeCatalog()
        guard catalog.allItemTypes.contains(where: { $0.id == id }) else { throw DatabaseError.itemTypeNotFound(id) }
        try await database.saveTypeSettings(.init(itemTypeID: id, isShared: availableEverywhere, isEditable: !catalog.readOnlyIDs.contains(id)))
    }

    @discardableResult
    func duplicateItemType(id: UUID, name: String) async throws -> ItemType {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.invalidItemType("Item type name is required.")
        }
        return try await createItemType(itemType(id: id).duplicated(name: trimmed))
    }

    func repairItemTypeDefinition(id: UUID, now: Date = .now) async throws -> ItemType {
        try await database.repairItemTypeDefinition(id: id, now: now)
    }

    func countItems(itemTypeID: UUID) async throws -> Int {
        try await database.countItems(itemTypeID: itemTypeID)
    }

    func itemTypeEditingImpact(id: UUID) async throws -> ItemTypeEditingImpact {
        guard try await database.fetchItemType(id: id) != nil else {
            throw DatabaseError.itemTypeNotFound(id)
        }
        let impact = try await database.itemTypeEditingImpact(itemTypeID: id)
        let decks = try await database.fetchAllDecks()
        let byID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        let usage = Set(try await database.fetchItems(itemTypeID: id).compactMap { $0.item.deckID })
        let shared = try await loadItemTypeCatalog().itemTypes.contains { $0.id == id }
        var paths: [String] = []
        for deck in decks {
            let policy = try await database.resolvedTypePolicy(deckID: deck.id)
            if usage.contains(deck.id) || policy?.itemTypes.contains(where: { $0.id == id }) == true || (shared && policy?.itemTypes.isEmpty != false) {
                paths.append(itemStoreDeckPath(for: deck.id, decksByID: byID))
            }
        }
        return .init(itemCount: impact.itemCount, deckCount: impact.deckCount, unassignedItemCount: impact.unassignedItemCount, deckPaths: paths.sorted())
    }

    /// Adopts the existing definition into the user's editable catalog without
    /// changing its identity, its items, or any deck policy references.
    @discardableResult
    func unlockItemType(id: UUID) async throws -> ItemType {
        guard let itemType = try await database.fetchItemType(id: id) else {
            throw DatabaseError.itemTypeNotFound(id)
        }
        let catalog = try await loadItemTypeCatalog()
        try await database.saveTypeSettings(.init(itemTypeID: id, isShared: catalog.itemTypes.contains { $0.id == id }, isEditable: true))
        return itemType
    }

    func itemTypeSchemaChangeImpact(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeSchemaChangeImpact {
        guard existing.id == updated.id else {
            throw DatabaseError.invalidItemType("The edited item type identity changed.")
        }
        let updatedFieldIDs = updated.fields.map(\.id)
        guard Set(updatedFieldIDs).count == updatedFieldIDs.count else {
            throw DatabaseError.invalidItemType("Item type field IDs must be unique.")
        }
        let updatedFields = Dictionary(uniqueKeysWithValues: updated.fields.map { ($0.id, $0) })
        let removed = existing.fields.filter { updatedFields[$0.id] == nil }
        let changed = existing.fields.filter { field in
            guard let updatedField = updatedFields[field.id] else { return false }
            return updatedField.type != field.type
        }
        let riskyIDs = Set((removed + changed).map(\.id))
        guard !riskyIDs.isEmpty else {
            return ItemTypeSchemaChangeImpact(
                affectedItemCount: 0,
                removedPopulatedFields: [],
                typeChangedPopulatedFields: []
            )
        }

        let items = try await database.fetchItems(itemTypeID: existing.id).map(\.item)
        let populatedIDs = Set(riskyIDs.filter { fieldID in
            items.contains { !$0.isFieldEmpty(fieldID) }
        })
        let affectedItems = items.filter { item in
            populatedIDs.contains { !item.isFieldEmpty($0) }
        }.count
        return ItemTypeSchemaChangeImpact(
            affectedItemCount: affectedItems,
            removedPopulatedFields: removed.filter { populatedIDs.contains($0.id) }.map(\.name),
            typeChangedPopulatedFields: changed.filter { populatedIDs.contains($0.id) }.map(\.name)
        )
    }

    /// Captures the exact retired-card, private-response, and stored-field state
    /// that a Studio confirmation authorizes. Commit recomputes this inside its
    /// write transaction.
    func prepareItemTypeUpdateAuthorization(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeUpdateAuthorization {
        guard existing.id == updated.id else {
            throw DatabaseError.invalidItemType("The edited item type identity changed.")
        }
        try ItemTypeValidation.validate(updated)
        return try await database.prepareItemTypeUpdateAuthorization(
            expectedOriginal: existing,
            updated: updated
        )
    }

    @discardableResult
    func deleteItemType(id: UUID) async throws -> Bool {
        guard try await database.fetchItemType(id: id) != nil else { return false }
        let itemCount = try await database.countItems(itemTypeID: id)
        if itemCount > 0 {
            throw DatabaseError.invalidItemType("Remove all items of this type before deleting it.")
        }
        try await database.deleteItemType(id: id)
        return true
    }

    @discardableResult
    func updateItemType(_ itemType: ItemType, now: Date = .now) async throws -> ItemType {
        let previous = try await database.fetchItemType(id: itemType.id)
        try ItemTypeValidation.validate(itemType)
        try await database.updateItemTypeAndSyncCards(previous: previous, updated: itemType, now: now)
        return itemType
    }

    /// Atomically compares the persisted definition, retired-card identities,
    /// private-response impact, and stored-field state with the values confirmed
    /// by Item Type Studio before reconciling cards.
    @discardableResult
    func updateItemType(
        _ itemType: ItemType,
        authorization: ItemTypeUpdateAuthorization,
        now: Date = .now
    ) async throws -> ItemType {
        guard itemType.id == authorization.expectedOriginal.id else {
            throw DatabaseError.invalidItemType("The edited item type identity changed.")
        }
        try ItemTypeValidation.validate(itemType)
        try await database.updateItemTypeAndSyncCards(
            updated: itemType,
            authorization: authorization,
            now: now
        )
        return itemType
    }
}

private func itemStoreDeckPath(for deckID: UUID, decksByID: [UUID: Deck]) -> String {
    var names: [String] = []
    var currentID: UUID? = deckID
    var visited: Set<UUID> = []
    while let id = currentID, visited.insert(id).inserted, let deck = decksByID[id] {
        names.append(deck.name)
        currentID = deck.parentID
    }
    return names.reversed().joined(separator: " / ")
}
