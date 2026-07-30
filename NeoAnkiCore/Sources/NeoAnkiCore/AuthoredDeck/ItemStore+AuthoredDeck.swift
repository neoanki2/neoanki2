import Foundation

extension ItemStore {
    func importAuthoredDeck(
        _ package: AuthoredDeckPackage,
        limits: PortableDeckLimits,
        now: Date
    ) async throws -> PortableDeckImportResult {
        let existingTypes = try await database.fetchAllItemTypes()
        let existingDigests = try Dictionary(
            uniqueKeysWithValues: existingTypes.map { ($0.id, try $0.portableSchemaDigest()) }
        )

        var typeMap: [UUID: ItemType] = [:]
        var resolvedByDigest: [String: ItemType] = [:]
        var createdTypes: [ItemType] = []
        var reusedTypeIDs: Set<UUID> = []
        for source in package.itemTypes {
            let digest = try source.portableSchemaDigest()
            if let resolved = resolvedByDigest[digest] {
                typeMap[source.id] = resolved
                reusedTypeIDs.insert(resolved.id)
                continue
            }
            if let existing = existingTypes
                .filter({ existingDigests[$0.id] == digest })
                .sorted(by: { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() })
                .first
            {
                typeMap[source.id] = existing
                resolvedByDigest[digest] = existing
                reusedTypeIDs.insert(existing.id)
            } else {
                typeMap[source.id] = source
                resolvedByDigest[digest] = source
                createdTypes.append(source)
            }
        }

        let sourceTypes = Dictionary(uniqueKeysWithValues: package.itemTypes.map { ($0.id, $0) })
        var importedItems: [PortableDeckPersistedItem] = []
        importedItems.reserveCapacity(package.items.count)
        // Authored item declaration order is the only sequence available to
        // builders. Give each item a distinct, already-due timestamp so browse
        // and first-study ordering survive UUID-backed persistence.
        let orderingStep: TimeInterval = 0.000_001
        let firstCreatedAt = now.addingTimeInterval(
            -Double(max(package.items.count - 1, 0)) * orderingStep
        )
        for (ordinal, record) in package.items.enumerated() {
            guard let sourceType = sourceTypes[record.item.itemTypeID],
                  let destinationType = typeMap[record.item.itemTypeID],
                  sourceType.fields.count == destinationType.fields.count else {
                throw AuthoredDeckError.invalid([
                    .init(
                        file: AuthoredDeck.manifestName,
                        line: 1,
                        code: "AD300",
                        message: "An authored item type could not be resolved."
                    ),
                ])
            }
            let sourceOrdinals = Dictionary(uniqueKeysWithValues:
                sourceType.fields.enumerated().map { ($0.element.id, $0.offset) }
            )
            let mappedFields = try record.item.fields.map { field -> FieldValue in
                guard let ordinal = sourceOrdinals[field.fieldID],
                      destinationType.fields.indices.contains(ordinal) else {
                    throw AuthoredDeckError.invalid([
                        .init(
                            file: AuthoredDeck.manifestName,
                            line: 1,
                            code: "AD301",
                            message: "An authored item field could not be resolved."
                        ),
                    ])
                }
                return FieldValue(
                    fieldID: destinationType.fields[ordinal].id,
                    value: field.value
                )
            }
            let orderedAt = firstCreatedAt.addingTimeInterval(Double(ordinal) * orderingStep)
            importedItems.append(.init(
                item: Item(
                    id: UUID(),
                    itemTypeID: destinationType.id,
                    fields: mappedFields,
                    tags: record.item.tags,
                    deckID: record.item.deckID
                ),
                createdAt: orderedAt,
                updatedAt: now
            ))
        }

        guard package.decks.count <= limits.maximumDecks,
              package.itemTypes.count <= limits.maximumItemTypes,
              importedItems.count <= limits.maximumItems else {
            throw PortableDeckError.limitExceeded("Authored deck exceeds import limits.")
        }

        let reservationScope = UUID()
        do {
            if !package.media.isEmpty, mediaStore == nil {
                throw PortableDeckError.mediaUnavailable
            }
            var reservationIDs: [String: UUID] = [:]
            for record in package.media {
                guard let mediaStore else { break }
                let ref = try await mediaStore.ingestVerifiedPortableFile(
                    url: record.fileURL,
                    expected: record.descriptor,
                    kind: record.descriptor.kind,
                    reservationScope: reservationScope
                )
                guard ref.assetHash == record.descriptor.hash,
                      let reservationID = ref.reservationID else {
                    throw PortableDeckError.invalidPackage(
                        "Authored media changed while it was being imported."
                    )
                }
                reservationIDs[ref.assetHash] = reservationID
            }
            importedItems = importedItems.map { record in
                .init(
                    item: authoredItemByApplyingReservations(
                        record.item,
                        reservationIDs: reservationIDs
                    ),
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
            }
            var seenIncludedTypeIDs: Set<UUID> = []
            let includedItemTypes = package.itemTypes.compactMap { source -> UUID? in
                guard let localID = typeMap[source.id]?.id,
                      seenIncludedTypeIDs.insert(localID).inserted else { return nil }
                return localID
            }.enumerated().map { ordinal, itemTypeID in
                IncludedItemTypeOwner(
                    rootDeckID: package.rootDeckID,
                    itemTypeID: itemTypeID,
                    ordinal: ordinal
                )
            }
            let resolvedPolicies = Dictionary(
                grouping: package.itemTypePolicies,
                by: \.deckID
            ).values.flatMap { sourceEntries -> [DeckItemTypePolicyEntry] in
                var orderedIDs: [UUID] = []
                var defaultIDs: Set<UUID> = []
                for entry in sourceEntries.sorted(by: { $0.ordinal < $1.ordinal }) {
                    guard let localID = typeMap[entry.itemTypeID]?.id else { continue }
                    if !orderedIDs.contains(localID) {
                        orderedIDs.append(localID)
                    }
                    if entry.isDefault {
                        defaultIDs.insert(localID)
                    }
                }
                guard let deckID = sourceEntries.first?.deckID else { return [] }
                return orderedIDs.enumerated().map { ordinal, itemTypeID in
                    DeckItemTypePolicyEntry(
                        deckID: deckID,
                        itemTypeID: itemTypeID,
                        ordinal: ordinal,
                        isDefault: defaultIDs.contains(itemTypeID)
                    )
                }
            }
            try await database.importPortableDeck(
                .init(
                    itemTypes: createdTypes,
                    libraryItemTypeIDs: package.usesIncludedItemTypes
                        ? []
                        : Set(typeMap.values.map(\.id)),
                    decks: package.decks,
                    items: importedItems,
                    mappings: [],
                    includedItemTypes: package.usesIncludedItemTypes ? includedItemTypes : [],
                    itemTypePolicies: package.usesIncludedItemTypes ? resolvedPolicies : []
                ),
                now: now,
                initialDueDates: Dictionary(
                    uniqueKeysWithValues: importedItems.map { ($0.item.id, $0.createdAt) }
                )
            )
            // The database transaction consumes committed reservations. Any
            // residual scope cleanup is best-effort after commit: reporting
            // failure here would invite a retry that duplicates imported data.
            try? await mediaStore?.releaseReservations(scopeID: reservationScope)
            return .init(
                deckIDs: [package.rootDeckID],
                itemCount: importedItems.count,
                createdItemTypeCount: createdTypes.count,
                reusedItemTypeCount: reusedTypeIDs.count
            )
        } catch {
            try? await mediaStore?.rollbackReservations(scopeID: reservationScope)
            throw error
        }
    }
}

private func authoredItemByApplyingReservations(
    _ item: Item,
    reservationIDs: [String: UUID]
) -> Item {
    var result = item
    result.fields = item.fields.map { field in
        guard case let .media(original) = field.value,
              let reservationID = reservationIDs[original.assetHash] else {
            return field
        }
        var ref = original
        ref.reservationID = reservationID
        return FieldValue(fieldID: field.fieldID, value: .media(ref))
    }
    return result
}
