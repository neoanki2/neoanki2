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
        try await database.insertLibraryItemType(itemType)
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
        let libraryIDs = try await database.fetchLibraryItemTypeIDs()
        let owners = try await database.fetchIncludedItemTypeOwners()
        let decks = try await database.fetchAllDecks()
        let typesByID = Dictionary(uniqueKeysWithValues: result.itemTypes.map { ($0.id, $0) })
        let decksByID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })

        let libraryTypes = result.itemTypes
            .filter { libraryIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let ownersByRoot = Dictionary(grouping: owners, by: \.rootDeckID)
        let includedGroups = ownersByRoot.compactMap { rootID, associations -> IncludedItemTypeGroup? in
            guard let rootDeck = decksByID[rootID] else { return nil }
            let included = associations
                .sorted { $0.ordinal < $1.ordinal }
                .compactMap { association -> ItemType? in
                    guard !libraryIDs.contains(association.itemTypeID) else { return nil }
                    return typesByID[association.itemTypeID]
                }
            guard !included.isEmpty else { return nil }
            return IncludedItemTypeGroup(
                rootDeck: rootDeck,
                deckPath: itemStoreDeckPath(for: rootDeck.id, decksByID: decksByID),
                itemTypes: included
            )
        }.sorted {
            $0.rootDeck.name.localizedCaseInsensitiveCompare($1.rootDeck.name) == .orderedAscending
        }

        return ItemTypeCatalog(
            itemTypes: libraryTypes,
            includedWithDecks: includedGroups,
            corruptions: result.corruptions
        )
    }

    func effectiveItemTypePolicy(for deckID: UUID) async throws -> DeckItemTypePolicy? {
        let decks = try await database.fetchAllDecks()
        let decksByID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        guard decksByID[deckID] != nil else { throw DatabaseError.deckNotFound(deckID) }
        let entries = try await database.fetchDeckItemTypePolicyEntries()
        let byDeck = Dictionary(grouping: entries, by: \.deckID)
        let typesByID = Dictionary(
            uniqueKeysWithValues: try await database.fetchAllItemTypes().map { ($0.id, $0) }
        )

        var currentID: UUID? = deckID
        var visited: Set<UUID> = []
        while let candidateID = currentID, visited.insert(candidateID).inserted {
            if let local = byDeck[candidateID], !local.isEmpty {
                let sorted = local.sorted { $0.ordinal < $1.ordinal }
                return DeckItemTypePolicy(
                    sourceDeckID: candidateID,
                    itemTypes: sorted.compactMap { typesByID[$0.itemTypeID] },
                    defaultItemTypeID: sorted.first(where: \.isDefault)?.itemTypeID
                )
            }
            currentID = decksByID[candidateID]?.parentID
        }
        return nil
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
