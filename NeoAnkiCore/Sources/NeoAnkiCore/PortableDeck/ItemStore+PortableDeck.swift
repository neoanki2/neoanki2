import Foundation

extension ItemStore {
    func portableDeckSnapshot(
        rootDeckID: UUID,
        limits: PortableDeckLimits,
        resolver: any PortableDeckTypeResolver
    ) async throws -> PortableDeckPackage {
        let librarySnapshot = try await database.portableDeckLibrarySnapshot()
        let allDecks = librarySnapshot.decks
        guard allDecks.contains(where: { $0.id == rootDeckID }) else {
            throw DatabaseError.deckNotFound(rootDeckID)
        }
        let summaries = allDecks.map {
            DeckSummary(id: $0.id, name: $0.name, parentID: $0.parentID, itemCount: 0, dueCount: 0)
        }
        let selectedIDs = DeckTree.descendantIDs(of: rootDeckID, in: summaries)
        guard selectedIDs.count <= limits.maximumDecks else {
            throw PortableDeckError.limitExceeded("Selected hierarchy contains too many decks.")
        }
        let byID = Dictionary(uniqueKeysWithValues: allDecks.map { ($0.id, $0) })
        let selectedDecks = allDecks
            .filter { selectedIDs.contains($0.id) }
            .sorted {
                deckDepth($0.id, root: rootDeckID, byID: byID)
                    < deckDepth($1.id, root: rootDeckID, byID: byID)
            }
            .map { deck in
                Deck(id: deck.id, name: deck.name, parentID: deck.id == rootDeckID ? nil : deck.parentID)
            }
        let persisted = librarySnapshot.items.filter {
            $0.item.deckID.map(selectedIDs.contains) == true
        }
        guard persisted.count <= limits.maximumItems else {
            throw PortableDeckError.limitExceeded("Selected hierarchy contains too many items.")
        }

        let explicitPoliciesByDeck = Dictionary(
            grouping: librarySnapshot.itemTypePolicies,
            by: \.deckID
        )
        var rootPolicySourceID: UUID? = rootDeckID
        var visited: Set<UUID> = []
        while let candidateID = rootPolicySourceID,
              visited.insert(candidateID).inserted,
              explicitPoliciesByDeck[candidateID]?.isEmpty != false {
            rootPolicySourceID = byID[candidateID]?.parentID
        }
        let inheritedRootPolicy = rootPolicySourceID
            .flatMap { explicitPoliciesByDeck[$0] }?
            .sorted { $0.ordinal < $1.ordinal } ?? []
        let directlyUsedTypeIDs = Set(persisted.map(\.item.itemTypeID))
        let rootPolicy: [DeckItemTypePolicyEntry]
        if inheritedRootPolicy.isEmpty {
            let sorted = directlyUsedTypeIDs.sorted { $0.uuidString < $1.uuidString }
            rootPolicy = sorted.enumerated().map { ordinal, itemTypeID in
                DeckItemTypePolicyEntry(
                    deckID: rootDeckID,
                    itemTypeID: itemTypeID,
                    ordinal: ordinal,
                    isDefault: sorted.count == 1
                )
            }
        } else {
            rootPolicy = inheritedRootPolicy.enumerated().map { ordinal, entry in
                DeckItemTypePolicyEntry(
                    deckID: rootDeckID,
                    itemTypeID: entry.itemTypeID,
                    ordinal: ordinal,
                    isDefault: entry.isDefault
                )
            }
        }
        let descendantPolicies = librarySnapshot.itemTypePolicies.filter {
            $0.deckID != rootDeckID && selectedIDs.contains($0.deckID)
        }
        let exportedPolicies = rootPolicy + descendantPolicies
        let ownedTypeIDs = Set(librarySnapshot.includedItemTypes.compactMap {
            selectedIDs.contains($0.rootDeckID) ? $0.itemTypeID : nil
        })
        let typeIDs = directlyUsedTypeIDs
            .union(ownedTypeIDs)
            .union(exportedPolicies.map(\.itemTypeID))
        guard typeIDs.count <= limits.maximumItemTypes else {
            throw PortableDeckError.limitExceeded("Selected hierarchy references too many item types.")
        }
        var types: [PortableDeckTypeRecord] = []
        let sourceLibraryID = librarySnapshot.libraryID
        let availableTypes = Dictionary(uniqueKeysWithValues:
            librarySnapshot.itemTypes.map { ($0.id, $0) }
        )
        let mappingsByLocalID = Dictionary(grouping:
            librarySnapshot.mappings,
            by: \.localTypeID
        )
        for typeID in typeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let itemType = availableTypes[typeID] else {
                throw PortableDeckError.invalidPackage("A referenced item type is unavailable.")
            }
            guard itemType.fields.count <= limits.maximumFieldsPerType,
                  itemType.templates.count <= limits.maximumTemplatesPerType else {
                throw PortableDeckError.limitExceeded("A referenced item type exceeds format limits.")
            }
            let mappedOrigin = mappingsByLocalID[itemType.id]?.first
            types.append(.init(
                itemType: itemType,
                originLibraryID: mappedOrigin?.originLibraryID ?? sourceLibraryID,
                originTypeID: mappedOrigin?.originTypeID ?? itemType.id,
                digest: try resolver.digest(for: itemType)
            ))
        }

        let records = persisted.map {
            PortableDeckPersistedItem(item: $0.item, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        guard records.allSatisfy({
            $0.item.tags.count <= limits.maximumTagsPerItem
                && $0.item.tags.allSatisfy {
                    $0.utf8.count <= 1_024
                        && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }) else {
            throw PortableDeckError.limitExceeded("An exported item has invalid or excessive tags.")
        }
        let references = records
            .flatMap(\.item.fields)
            .compactMap { field -> MediaRef? in
                guard case let .media(ref) = field.value else { return nil }
                return ref
            }
        let uniqueReferences = Dictionary(grouping: references, by: \.assetHash)
            .compactMapValues(\.first)
        guard uniqueReferences.count <= limits.maximumMediaAssets else {
            throw PortableDeckError.limitExceeded("Selected hierarchy references too many media assets.")
        }
        if !references.isEmpty, mediaStore == nil {
            throw PortableDeckError.mediaUnavailable
        }

        var media: [PortableDeckMediaRecord] = []
        var totalBytes: Int64 = 0
        for hash in uniqueReferences.keys.sorted() {
            guard let ref = uniqueReferences[hash], let mediaStore = self.mediaStore else { continue }
            let descriptor = try await mediaStore.descriptor(for: ref)
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(Int64(descriptor.byteSize))
            guard !overflow, newTotal <= limits.maximumTotalMediaBytes else {
                throw PortableDeckError.limitExceeded("Selected hierarchy contains too much media.")
            }
            let url = try await mediaStore.resolve(ref)
            totalBytes = newTotal
            media.append(.init(descriptor: descriptor, fileURL: url))
        }
        return .init(
            formatVersion: PortableDeck.version,
            sourceLibraryID: sourceLibraryID,
            rootDeckID: rootDeckID,
            decks: selectedDecks,
            types: types,
            items: records,
            media: media,
            itemTypePolicies: exportedPolicies
        )
    }

    func importPortableDeck(
        _ package: PortableDeckPackage,
        limits: PortableDeckLimits,
        resolver: any PortableDeckTypeResolver,
        conflictResolution: PortableDeckTypeConflictResolution,
        now: Date
    ) async throws -> PortableDeckImportResult {
        let existingTypes = try await database.fetchAllItemTypes()
        let existingDigests = try Dictionary(
            uniqueKeysWithValues: existingTypes.map { ($0.id, try resolver.digest(for: $0)) }
        )
        let allMappings = try await database.allPortableItemTypeMappings()
        let mappingsByOrigin = Dictionary(grouping: allMappings) {
            "\($0.originLibraryID.uuidString.lowercased())/\($0.originTypeID.uuidString.lowercased())"
        }

        var typeMap: [UUID: ItemType] = [:]
        var createdTypes: [ItemType] = []
        var reusedCount = 0
        for record in package.types {
            // Recompute instead of trusting the package's claimed digest.
            let actualDigest = try resolver.digest(for: record.itemType)
            guard actualDigest == record.digest else {
                throw PortableDeckError.invalidPackage("An item type digest is invalid.")
            }
            let originKey =
                "\(record.originLibraryID.uuidString.lowercased())/\(record.originTypeID.uuidString.lowercased())"
            let originMappings = mappingsByOrigin[originKey] ?? []
            if let exactMapping = originMappings.first(where: { $0.digest == record.digest }),
               let existing = existingTypes.first(where: {
                   $0.id == exactMapping.localTypeID && existingDigests[$0.id] == record.digest
               }) {
                typeMap[record.itemType.id] = existing
                reusedCount += 1
                continue
            }
            if let conflict = originMappings.first {
                switch conflictResolution {
                case .reject:
                    throw PortableDeckError.typeConflict(
                        origin: originKey,
                        existingDigest: existingDigests[conflict.localTypeID] ?? conflict.digest,
                        importedDigest: record.digest
                    )
                case .useMatchingSchema:
                    guard let existing = existingTypes
                        .filter({ existingDigests[$0.id] == record.digest })
                        .sorted(by: {
                            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
                        })
                        .first
                    else {
                        throw PortableDeckError.typeConflict(
                            origin: originKey,
                            existingDigest: existingDigests[conflict.localTypeID] ?? conflict.digest,
                            importedDigest: record.digest
                        )
                    }
                    typeMap[record.itemType.id] = existing
                    reusedCount += 1
                    continue
                case .importAsDistinctRevision:
                    let created = remappedPortableType(record.itemType)
                    typeMap[record.itemType.id] = created
                    createdTypes.append(created)
                    continue
                }
            }
            if let existing = existingTypes.first(where: {
                $0.id == record.itemType.id && existingDigests[$0.id] == record.digest
            }) {
                typeMap[record.itemType.id] = existing
                reusedCount += 1
            } else if let existing = existingTypes
                .filter({ existingDigests[$0.id] == record.digest })
                .sorted(by: { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() })
                .first {
                typeMap[record.itemType.id] = existing
                reusedCount += 1
            } else {
                let created = remappedPortableType(record.itemType)
                typeMap[record.itemType.id] = created
                createdTypes.append(created)
            }
        }

        var deckMap: [UUID: UUID] = [:]
        for deck in package.decks { deckMap[deck.id] = UUID() }
        let importedDecks = try package.decks.map { deck -> Deck in
            guard let id = deckMap[deck.id] else {
                throw PortableDeckError.invalidPackage("Deck mapping failed.")
            }
            let parentID = try deck.parentID.map { oldParent -> UUID in
                guard let mapped = deckMap[oldParent] else {
                    throw PortableDeckError.invalidPackage("Deck parent mapping failed.")
                }
                return mapped
            }
            return Deck(id: id, name: deck.name, parentID: parentID)
        }

        guard package.items.count <= limits.maximumItems else {
            throw PortableDeckError.limitExceeded("Portable deck contains too many items.")
        }
        let sourceTypesByID = Dictionary(uniqueKeysWithValues:
            package.types.map { ($0.itemType.id, $0.itemType) }
        )
        let sourceOrdinalsByTypeID = Dictionary(uniqueKeysWithValues:
            package.types.map { record in
                (
                    record.itemType.id,
                    Dictionary(uniqueKeysWithValues:
                        record.itemType.fields.enumerated().map { ($0.element.id, $0.offset) }
                    )
                )
            }
        )
        var importedItems: [PortableDeckPersistedItem] = []
        importedItems.reserveCapacity(package.items.count)
        for record in package.items {
            guard let type = typeMap[record.item.itemTypeID],
                  let oldDeckID = record.item.deckID,
                  let deckID = deckMap[oldDeckID]
            else { throw PortableDeckError.invalidPackage("Item references are invalid.") }
            guard sourceTypesByID[record.item.itemTypeID] != nil,
                  let sourceOrdinals = sourceOrdinalsByTypeID[record.item.itemTypeID]
            else {
                throw PortableDeckError.invalidPackage("Item source type is missing.")
            }
            let mappedFields = try record.item.fields.map { field -> FieldValue in
                guard let ordinal = sourceOrdinals[field.fieldID], ordinal < type.fields.count else {
                    throw PortableDeckError.invalidPackage("Item field ordinal is invalid.")
                }
                return FieldValue(fieldID: type.fields[ordinal].id, value: field.value)
            }
            try validatePortableFields(mappedFields, against: type)
            importedItems.append(.init(
                item: Item(
                    id: UUID(),
                    itemTypeID: type.id,
                    fields: mappedFields,
                    tags: record.item.tags,
                    deckID: deckID
                ),
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            ))
        }

        let reservationScope = UUID()
        do {
            var reservationIDs: [String: UUID] = [:]
            if !package.media.isEmpty, mediaStore == nil {
                throw PortableDeckError.mediaUnavailable
            }
            for record in package.media {
                guard let mediaStore else { break }
                let ref = try await mediaStore.ingestVerifiedPortableFile(
                    url: record.fileURL,
                    expected: record.descriptor,
                    kind: record.descriptor.kind,
                    reservationScope: reservationScope
                )
                guard ref.assetHash == record.descriptor.hash, let reservationID = ref.reservationID else {
                    throw PortableDeckError.invalidPackage("Media hash changed while staging import.")
                }
                reservationIDs[ref.assetHash] = reservationID
            }
            importedItems = importedItems.map { record in
                .init(
                    item: itemByApplyingReservations(record.item, reservationIDs: reservationIDs),
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
            }

            guard let importedRootDeckID = deckMap[package.rootDeckID] else {
                throw PortableDeckError.invalidPackage("Root deck mapping failed.")
            }
            let resolvedTypeIDs = Set(typeMap.values.map(\.id))
            let includedItemTypes: [IncludedItemTypeOwner]
            let libraryItemTypeIDs: Set<UUID>
            let itemTypePolicies: [DeckItemTypePolicyEntry]
            if package.formatVersion >= 3 {
                libraryItemTypeIDs = []
                includedItemTypes = resolvedTypeIDs
                    .sorted { $0.uuidString < $1.uuidString }
                    .enumerated()
                    .map { ordinal, itemTypeID in
                        IncludedItemTypeOwner(
                            rootDeckID: importedRootDeckID,
                            itemTypeID: itemTypeID,
                            ordinal: ordinal
                        )
                    }
                itemTypePolicies = try Dictionary(
                    grouping: package.itemTypePolicies,
                    by: \.deckID
                ).values.flatMap { sourceEntries -> [DeckItemTypePolicyEntry] in
                    guard let sourceDeckID = sourceEntries.first?.deckID,
                          let deckID = deckMap[sourceDeckID] else { return [] }
                    var orderedIDs: [UUID] = []
                    var defaultIDs: Set<UUID> = []
                    for entry in sourceEntries.sorted(by: { $0.ordinal < $1.ordinal }) {
                        guard let itemTypeID = typeMap[entry.itemTypeID]?.id else {
                            throw PortableDeckError.invalidPackage(
                                "Deck item-type policy mapping failed."
                            )
                        }
                        if !orderedIDs.contains(itemTypeID) {
                            orderedIDs.append(itemTypeID)
                        }
                        if entry.isDefault {
                            defaultIDs.insert(itemTypeID)
                        }
                    }
                    return orderedIDs.enumerated().map { ordinal, itemTypeID in
                        DeckItemTypePolicyEntry(
                            deckID: deckID,
                            itemTypeID: itemTypeID,
                            ordinal: ordinal,
                            isDefault: defaultIDs.contains(itemTypeID)
                        )
                    }
                }
            } else {
                libraryItemTypeIDs = resolvedTypeIDs
                includedItemTypes = []
                itemTypePolicies = []
            }

            try await database.importPortableDeck(
                .init(
                    itemTypes: createdTypes,
                    libraryItemTypeIDs: libraryItemTypeIDs,
                    decks: importedDecks,
                    items: importedItems,
                    mappings: package.types.compactMap { record in
                        guard let local = typeMap[record.itemType.id] else { return nil }
                        return .init(
                            originLibraryID: record.originLibraryID,
                            originTypeID: record.originTypeID,
                            digest: record.digest,
                            localTypeID: local.id
                        )
                    },
                    includedItemTypes: includedItemTypes,
                    itemTypePolicies: itemTypePolicies
                ),
                now: now
            )
            try await mediaStore?.releaseReservations(scopeID: reservationScope)
            return .init(
                deckIDs: [importedRootDeckID],
                itemCount: importedItems.count,
                createdItemTypeCount: createdTypes.count,
                reusedItemTypeCount: reusedCount
            )
        } catch {
            try? await mediaStore?.rollbackReservations(scopeID: reservationScope)
            throw error
        }
    }
}

private func validatePortableFields(_ fields: [FieldValue], against itemType: ItemType) throws {
    let definitions = Dictionary(uniqueKeysWithValues: itemType.fields.map { ($0.id, $0) })
    guard fields.count <= definitions.count,
          Set(fields.map(\.fieldID)).count == fields.count,
          fields.allSatisfy({ definitions[$0.fieldID] != nil })
    else { throw PortableDeckError.invalidPackage("Item fields do not match their item type.") }
    for field in fields {
        guard let definition = definitions[field.fieldID],
              portableValue(field.value, matches: definition.type)
        else {
            throw PortableDeckError.invalidPackage("An item field has the wrong content type.")
        }
    }
    for definition in itemType.fields where definition.isRequired {
        guard let value = fields.first(where: { $0.fieldID == definition.id })?.value,
              !value.isEmpty else {
            throw PortableDeckError.invalidPackage("A required imported field is empty.")
        }
    }
}

private func portableValue(_ value: ContentValue, matches type: FieldType) -> Bool {
    if case .empty = value { return true }
    switch (type, value) {
    case (.text, .text), (.richText, .rich), (.number, .number), (.cloze, .cloze):
        return true
    case let (.audio, .media(ref)): return ref.kind == .audio
    case let (.image, .media(ref)): return ref.kind == .image
    case let (.gif, .media(ref)): return ref.kind == .gif
    case let (.video, .media(ref)): return ref.kind == .video
    default: return false
    }
}

private func remappedPortableType(_ source: ItemType) -> ItemType {
    let fields = source.fields.map {
        FieldDef(name: $0.name, type: $0.type, isRequired: $0.isRequired)
    }
    let idMap = Dictionary(uniqueKeysWithValues:
        zip(source.fields.map(\.id), fields.map(\.id))
    )
    let templates = source.templates.map { template in
        Template(
            name: template.name,
            prompt: remappedSide(template.prompt, ids: idMap),
            answer: remappedSide(template.answer, ids: idMap),
            interaction: template.interaction,
            skill: template.skill,
            generateWhen: template.generateWhen.map { remappedCondition($0, ids: idMap) }
        )
    }
    return ItemType(name: source.name, fields: fields, templates: templates)
}

private func remappedSide(_ side: Side, ids: [UUID: UUID]) -> Side {
    Side(slots: side.slots.map { slot in
        let source: SlotSource
        switch slot.source {
        case let .field(id): source = .field(ids[id] ?? id)
        case let .literal(value): source = .literal(value)
        }
        return Slot(source: source, presentation: slot.presentation)
    })
}

private func remappedCondition(_ condition: SlotCondition, ids: [UUID: UUID]) -> SlotCondition {
    switch condition {
    case let .fieldNotEmpty(id): .fieldNotEmpty(ids[id] ?? id)
    case let .fieldEmpty(id): .fieldEmpty(ids[id] ?? id)
    case let .all(children): .all(children.map { remappedCondition($0, ids: ids) })
    case let .any(children): .any(children.map { remappedCondition($0, ids: ids) })
    }
}

private func itemByApplyingReservations(
    _ item: Item,
    reservationIDs: [String: UUID]
) -> Item {
    var result = item
    result.fields = item.fields.map { field in
        guard case let .media(original) = field.value,
              let reservationID = reservationIDs[original.assetHash]
        else { return field }
        var ref = original
        ref.reservationID = reservationID
        return FieldValue(fieldID: field.fieldID, value: .media(ref))
    }
    return result
}

private func deckDepth(_ id: UUID, root: UUID, byID: [UUID: Deck]) -> Int {
    var depth = 0
    var cursor = id
    var visited: Set<UUID> = []
    while cursor != root, visited.insert(cursor).inserted, let parent = byID[cursor]?.parentID {
        depth += 1
        cursor = parent
    }
    return depth
}
