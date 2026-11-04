import Foundation
import NeoAnkiApplication
import NeoAnkiCloudSync
import NeoAnkiCore
import Testing

@Test func synchronizedItemMustRejectAValueWithTheWrongFieldType() async throws {
    let fixture = try await makeSyncRepository()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let type = try #require(try await fixture.repository.loadItemTypes().itemTypes.first)
    let invalid = Item(itemTypeID: type.id, fields: type.fields.map {
        FieldValue(fieldID: $0.id, value: .number(123))
    })
    await #expect(throws: (any Error).self) {
        try await fixture.repository.applySynchronizedBatch([.item(invalid, createdAt: .now, updatedAt: .now)])
    }
    #expect(try await fixture.repository.item(id: invalid.id) == nil)
}

@Test func initialMergeKeepsEquivalentSchemasWithIndependentTemplateIDs() async throws {
    let local = try await makeSyncRepository(), remote = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: local.directory)
        try? FileManager.default.removeItem(at: remote.directory)
    }
    let base = try #require(try await local.repository.loadItemTypes().itemTypes.first)
    let templates = base.templates.map {
        Template(id: UUID(), name: $0.name, layout: $0.layout, components: $0.components,
            interaction: $0.interaction, skill: $0.skill, generateWhen: $0.generateWhen)
    }
    let type = ItemType(name: base.name, fields: base.fields, templates: templates)
    #expect(try PortableItemTypeIdentity.schemaDigest(of: base) == PortableItemTypeIdentity.schemaDigest(of: type))
    _ = try await remote.repository.createItemType(type)
    let item = Item(itemTypeID: type.id, fields: type.fields.map {
        FieldValue(fieldID: $0.id, value: .text("remote"))
    })
    _ = try await remote.repository.createItem(item, asOf: .now)
    let records = try await SQLiteLibrarySyncAdapter(repository: remote.repository).initialMerge(remote: [], deviceID: "remote")
    _ = try await SQLiteLibrarySyncAdapter(repository: local.repository).initialMerge(remote: records, deviceID: "local")
    #expect(try await local.repository.item(id: item.id)?.item.itemTypeID == type.id)
    #expect(try await local.repository.loadItemTypes().itemTypes.contains { $0.id == type.id })
    let card = try #require(try await local.repository.cards().first { $0.itemID == item.id })
    #expect(type.templates.contains { $0.id == card.templateID })
}

@Test func linkedLibrariesTreatChangedValuesAsUpdatesInsteadOfIdentityCollisions() async throws {
    let local = try await makeSyncRepository()
    let cloud = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: local.directory)
        try? FileManager.default.removeItem(at: cloud.directory)
    }
    let id = UUID()
    _ = try await local.repository.createDeck(Deck(id: id, name: "Before edit"))
    _ = try await cloud.repository.createDeck(Deck(id: id, name: "After edit"))
    try await local.repository.recordLibraryAlias(cloud.repository.libraryID(), canonicalID: local.repository.libraryID())
    let records = try await SQLiteLibrarySyncAdapter(repository: cloud.repository).initialMerge(remote: [], deviceID: "cloud")
    _ = try await SQLiteLibrarySyncAdapter(repository: local.repository).initialMerge(remote: records, deviceID: "local")
    let decks = try await local.repository.deckSummaries(asOf: .now)
    #expect(decks.count == 1)
    #expect(decks.first?.id == id)
    #expect(decks.first?.name == "After edit")
}

@Test func initialMergeIncludesResourcesMissingFromRetainedJournal() async throws {
    let source = try await makeSyncRepository()
    let destination = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: source.directory)
        try? FileManager.default.removeItem(at: destination.directory)
    }
    let deck = try await source.repository.createDeck(Deck(name: "Before retained history"))
    _ = try await source.repository.createDeck(Deck(name: "Retained change"))
    let store = try ItemStore(databaseURL: source.directory.appendingPathComponent("library.sqlite"))
    _ = try await store.pruneLibraryChanges(asOf: .distantFuture, retentionInterval: 0, minimumRetained: 1)
    #expect(try await source.repository.changes(after: 0, limit: 1_000).allSatisfy { $0.resourceID != deck.id.uuidString })
    let snapshot = try await SQLiteLibrarySyncAdapter(repository: source.repository).initialMerge(remote: [], deviceID: "source")
    #expect(snapshot.contains { $0.resourceKind == "deck" && $0.id == deck.id.uuidString })
    _ = try await SQLiteLibrarySyncAdapter(repository: destination.repository).initialMerge(remote: snapshot, deviceID: "destination")
    #expect(try await destination.repository.deck(id: deck.id).name == "Before retained history")
}

@Test func sqliteSyncAdapterAppliesChildDeckBeforeParentAtomically() async throws {
    let source = try await makeSyncRepository()
    let destination = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: source.directory)
        try? FileManager.default.removeItem(at: destination.directory)
    }
    let cursor = try await source.repository.currentChangeCursor()
    let parent = Deck(name: "Parent")
    let child = Deck(name: "Child", parentID: parent.id)
    try await source.repository.applySynchronizedBatch([.deck(child), .deck(parent)])
    let adapter = SQLiteLibrarySyncAdapter(repository: source.repository)
    let records = try await adapter.encode(changes: source.repository.changes(after: cursor, limit: 100), deviceID: "source")
    try await SQLiteLibrarySyncAdapter(repository: destination.repository).applyRemote(records, origin: .cloud)
    #expect(try await destination.repository.deck(id: child.id).parentID == parent.id)
    #expect(try await destination.repository.deck(id: parent.id).name == "Parent")
    let orphan = Deck(name: "Missing parent", parentID: UUID())
    let unrelated = Deck(name: "Must roll back")
    await #expect(throws: (any Error).self) {
        try await destination.repository.applySynchronizedBatch([.deck(unrelated), .deck(orphan)])
    }
    let summaries = try await destination.repository.deckSummaries(asOf: .now)
    #expect(!summaries.contains { $0.id == orphan.id || $0.id == unrelated.id })
}

@Test func initialMergeKeepsExistingTypeIdentitiesWithEquivalentSchemas() async throws {
    let fixture = try await makeSyncRepository()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try #require(try await fixture.repository.loadItemTypes().itemTypes.first)
    let duplicate = ItemType(name: "Equivalent schema", fields: original.fields, templates: original.templates)
    _ = try await fixture.repository.createItemType(duplicate)
    let deck = try await fixture.repository.createDeck(Deck(name: "Two equivalent types"))
    let first = ItemTypeMembershipRecord.included(rootDeckID: deck.id, itemTypeID: original.id, ordinal: 0)
    let second = ItemTypeMembershipRecord.included(rootDeckID: deck.id, itemTypeID: duplicate.id, ordinal: 1)
    try await fixture.repository.applySynchronizedBatch([.itemTypeMembership(first), .itemTypeMembership(second)])
    let item = Item(itemTypeID: original.id, fields: original.fields.map {
        FieldValue(fieldID: $0.id, value: $0.type == .richText ? .rich([Span("Value")]) : .text("Value"))
    }, deckID: deck.id)
    let timestamp = Date(timeIntervalSince1970: 1_783_000_000.1234567)
    _ = try await fixture.repository.createItem(item, asOf: timestamp)
    let card = try #require(try await fixture.repository.cards().first { $0.itemID == item.id })
    _ = try await fixture.repository.submitReview(cardID: card.id, rating: .good, asOf: timestamp, durationMilliseconds: 10)
    let adapter = SQLiteLibrarySyncAdapter(repository: fixture.repository)
    let records = try await adapter.encode(changes: fixture.repository.changes(after: 0, limit: 1_000), deviceID: "cloud")
    let outbound = try await adapter.initialMerge(remote: records, deviceID: "local")
    #expect(outbound.isEmpty)
    #expect(try await fixture.repository.itemTypeMembershipRecord(id: first.id) == first)
    #expect(try await fixture.repository.itemTypeMembershipRecord(id: second.id) == second)
}

@Test func initialMergeSkipsHistoricalCreateForDeletedDeck() async throws {
    let fixture = try await makeSyncRepository()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let deck = try await fixture.repository.createDeck(Deck(name: "Deleted before sync"))
    try await fixture.repository.commitDeckDeletion(id: deck.id, policy: .unassignItems, asOf: .now)
    let adapter = SQLiteLibrarySyncAdapter(repository: fixture.repository)
    let merged = try await adapter.initialMerge(remote: [], deviceID: "local")
    #expect(merged.contains { $0.resourceKind == "deck" && $0.id == deck.id.uuidString && $0.isTombstone })
}

@Test func itemTypeSyncEnvelopeKeepsCloudKitPayloadContractStable() async throws {
    let fixture = try await makeSyncRepository()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let repository = fixture.repository
    let cursor = try await repository.currentChangeCursor()
    let frontID = UUID(uuidString: "41000000-0000-4000-8000-000000000001")!
    let backID = UUID(uuidString: "41000000-0000-4000-8000-000000000002")!
    let templateID = UUID(uuidString: "42000000-0000-4000-8000-000000000001")!
    let type = ItemType(
        id: UUID(uuidString: "43000000-0000-4000-8000-000000000001")!,
        name: "Sync Contract",
        fields: [
            FieldDef(id: frontID, name: "Front", type: .text, isRequired: true),
            FieldDef(id: backID, name: "Back", type: .text, isRequired: true),
        ],
        templates: [Template(
            id: templateID,
            name: "Card",
            layout: .split,
            components: [
                TemplateComponent(
                    id: UUID(uuidString: "44000000-0000-4000-8000-000000000001")!,
                    region: .primary,
                    purpose: .question,
                    source: .field(frontID)
                ),
                TemplateComponent(
                    id: UUID(uuidString: "44000000-0000-4000-8000-000000000002")!,
                    region: .secondary,
                    purpose: .expectedAnswer,
                    source: .field(backID),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ],
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recall)
        )]
    )
    _ = try await repository.createItemType(type)

    let adapter = SQLiteLibrarySyncAdapter(repository: repository)
    let changes = try await repository.changes(after: cursor, limit: 100)
    let envelope = try #require(
        try await adapter.encode(changes: changes, deviceID: "contract-device")
            .first { $0.resourceKind == LibraryResourceKind.itemType.rawValue }
    )

    #expect(envelope.id == type.id.uuidString)
    #expect(envelope.resourceKind == "itemType")
    #expect(envelope.deviceID == "contract-device")
    #expect(envelope.revision == 1)
    #expect(envelope.isTombstone == false)
    #expect(envelope.asset == nil)
    #expect(String(data: envelope.payload, encoding: .utf8) == #"{"itemType":{"_0":{"fields":[{"id":"41000000-0000-4000-8000-000000000001","isRequired":true,"name":"Front","type":"text"},{"id":"41000000-0000-4000-8000-000000000002","isRequired":true,"name":"Back","type":"text"}],"id":"43000000-0000-4000-8000-000000000001","name":"Sync Contract","templates":[{"components":[{"id":"44000000-0000-4000-8000-000000000001","presentation":{"media":"default","reveal":"always"},"purpose":"question","region":"primary","source":{"field":{"_0":"41000000-0000-4000-8000-000000000001"}}},{"id":"44000000-0000-4000-8000-000000000002","presentation":{"media":"default","reveal":"hiddenUntilAnswer"},"purpose":"expectedAnswer","region":"secondary","source":{"field":{"_0":"41000000-0000-4000-8000-000000000002"}}}],"id":"42000000-0000-4000-8000-000000000001","interaction":"reveal","layout":"split","name":"Card","skill":{"input":"text","operation":"recall","output":"text"}}]}}}"#)
}

@Test func sqliteSyncAdapterReplicatesDeckAndTombstone() async throws {
    let source = try await makeSyncRepository()
    let destination = try await makeSyncRepository()
    let sourceAdapter = SQLiteLibrarySyncAdapter(repository: source.repository)
    let destinationAdapter = SQLiteLibrarySyncAdapter(repository: destination.repository)
    let cursor = try await source.repository.currentChangeCursor()

    let deck = try await source.repository.createDeck(Deck(name: "Replicated"))
    let created = try await source.repository.changes(after: cursor, limit: 100)
    let envelopes = try await sourceAdapter.encode(changes: created, deviceID: "source")
    try await destinationAdapter.applyRemote(envelopes, origin: .cloud)
    #expect(try await destination.repository.deck(id: deck.id).name == "Replicated")

    let deleteCursor = try await source.repository.currentChangeCursor()
    try await source.repository.commitDeckDeletion(id: deck.id, policy: .unassignItems, asOf: .now)
    let deleted = try await source.repository.changes(after: deleteCursor, limit: 100)
    try await destinationAdapter.applyRemote(
        try await sourceAdapter.encode(changes: deleted, deviceID: "source"),
        origin: .cloud
    )
    await #expect(throws: (any Error).self) { try await destination.repository.deck(id: deck.id) }
}

@Test func sqliteSyncAdapterRejectsCorruptStagedMedia() async throws {
    let source = try await makeSyncRepository()
    let destination = try await makeSyncRepository()
    let adapter = SQLiteLibrarySyncAdapter(repository: source.repository)
    let destinationAdapter = SQLiteLibrarySyncAdapter(repository: destination.repository)
    let cursor = try await source.repository.currentChangeCursor()
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    _ = try await source.repository.reserveMedia(
        data: png,
        kind: .image,
        altText: "Test image",
        reservationID: UUID(),
        asOf: .now
    )
    let changes = try await source.repository.changes(after: cursor, limit: 100)
    let encoded = try await adapter.encode(changes: changes, deviceID: "source")
    let media = try #require(encoded.first(where: { $0.resourceKind == "media" }))
    let descriptor = try #require(media.asset)
    let corrupted = SyncRecordEnvelope(
        id: media.id,
        resourceKind: media.resourceKind,
        revision: media.revision,
        deviceID: media.deviceID,
        order: media.order,
        isTombstone: false,
        payload: media.payload,
        asset: SyncAssetDescriptor(
            hash: String(repeating: "0", count: 64),
            byteSize: descriptor.byteSize,
            signature: descriptor.signature,
            fileExtension: descriptor.fileExtension,
            contentType: descriptor.contentType
        ),
        stagedFileURL: media.stagedFileURL
    )
    await #expect(throws: SQLiteLibrarySyncError.self) {
        try await destinationAdapter.applyRemote([corrupted], origin: .cloud)
    }
}

@Test func syncAdapterExcludesResponsesAndPrivateOnlyMediaButAllowsSharedOrdinaryBytes() async throws {
    let fixture = try await makeSyncRepository()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let repository = fixture.repository
    let prompt = FieldDef(name: "Prompt", type: .text, isRequired: true)
    let submissionTemplate = Template(
        name: "Submission",
        prompt: Side(slots: [Slot(source: .field(prompt.id))]),
        answer: Side(slots: []),
        interaction: .audioSubmission,
        skill: Skill(input: .text, output: .audio, operation: .explain)
    )
    let submissionType = ItemType(
        name: "Submission",
        fields: [prompt],
        templates: [submissionTemplate]
    )
    _ = try await repository.createItemType(submissionType)
    let submissionItem = Item(
        itemTypeID: submissionType.id,
        fields: [FieldValue(fieldID: prompt.id, value: .text("Speak"))]
    )
    _ = try await repository.createItem(submissionItem)
    let card = try #require(try await repository.cards().first { $0.itemID == submissionItem.id })
    let draftURL = fixture.directory.appendingPathComponent("draft.m4a")
    try Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8)).write(to: draftURL)
    let cursor = try await repository.currentChangeCursor()
    let response = try await repository.completeAudioSubmission(StudyResponseDraft(
        cardID: card.id,
        fileURL: draftURL,
        durationMilliseconds: 10_000,
        capturedAt: .now
    ))
    let adapter = SQLiteLibrarySyncAdapter(repository: repository)
    let privateEnvelopes = try await adapter.encode(
        changes: try await repository.changes(after: cursor, limit: 100),
        deviceID: "local"
    )
    #expect(!privateEnvelopes.contains { $0.resourceKind == "studyResponse" })
    #expect(!privateEnvelopes.contains { $0.resourceKind == "media" && $0.id == response.mediaHash })

    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let audio = FieldDef(name: "Reference audio", type: .audio, isRequired: true)
    let ordinaryType = ItemType(
        name: "Ordinary audio",
        fields: [front, audio],
        templates: [Template(
            name: "Listen",
            prompt: Side(slots: [Slot(source: .field(front.id))]),
            answer: Side(slots: [Slot(source: .field(audio.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .audio, operation: .recognize)
        )]
    )
    _ = try await repository.createItemType(ordinaryType)
    let sharedCursor = try await repository.currentChangeCursor()
    _ = try await repository.createItem(Item(
        itemTypeID: ordinaryType.id,
        fields: [
            FieldValue(fieldID: front.id, value: .text("Listen")),
            FieldValue(fieldID: audio.id, value: .media(MediaRef(
                kind: .audio,
                assetHash: response.mediaHash,
                fileExtension: "m4a",
                altText: "Reference recording"
            )))
        ]
    ))
    let sharedEnvelopes = try await adapter.encode(
        changes: try await repository.changes(after: sharedCursor, limit: 100),
        deviceID: "local"
    )
    #expect(sharedEnvelopes.contains { $0.resourceKind == "media" && $0.id == response.mediaHash })
}

@Test func initialMergePreservesAndRestoresMutableConflictAsNewResource() async throws {
    let local = try await makeSyncRepository()
    let cloudDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-sync-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
    let cloudURL = cloudDirectory.appendingPathComponent("library.sqlite")
    try await local.repository.createBackup(at: cloudURL)
    let cloud = SyncRepositoryFixture(
        repository: try SQLiteLibraryRepository(databaseURL: cloudURL),
        directory: cloudDirectory
    )
    try await cloud.repository.bootstrap()
    let id = UUID()
    _ = try await local.repository.createDeck(Deck(id: id, name: "Local wording"))
    _ = try await cloud.repository.createDeck(Deck(id: id, name: "Cloud wording"))
    let cloudAdapter = SQLiteLibrarySyncAdapter(repository: cloud.repository)
    let localAdapter = SQLiteLibrarySyncAdapter(repository: local.repository)
    let remote = try await cloudAdapter.encode(
        changes: try await cloud.repository.changes(after: 0, limit: 1_000),
        deviceID: "cloud"
    )

    _ = try await localAdapter.initialMerge(remote: remote, deviceID: "local")
    let copy = try #require(await localAdapter.preservedConflictCopies().first(where: { $0.originalResourceID == id.uuidString }))
    #expect(try await local.repository.deck(id: id).name == "Cloud wording")
    try await localAdapter.restoreConflictCopy(copy)
    #expect(try await local.repository.deckSummaries(asOf: .now).contains(where: { $0.name == "Local wording (Recovered)" }))
    // Simulate death after domain commit but before the issue is acknowledged.
    let restarted = SQLiteLibrarySyncAdapter(repository: local.repository)
    try await restarted.restoreConflictCopy(copy)
    #expect(try await local.repository.deckSummaries(asOf: .now).filter { $0.name == "Local wording (Recovered)" }.count == 1)
    #expect(try await local.repository.deck(id: copy.id).name == "Local wording (Recovered)")
}

@Test func initialMergeDeterministicallyRemapsCrossLibraryIdentifierCollisions() async throws {
    let local = try await makeSyncRepository()
    let cloud = try await makeSyncRepository()
    let sharedDeckID = UUID()
    _ = try await local.repository.createDeck(Deck(id: sharedDeckID, name: "Local deck"))
    _ = try await cloud.repository.createDeck(Deck(id: sharedDeckID, name: "Cloud deck"))
    let type = try #require(try await cloud.repository.loadItemTypes().itemTypes.first)
    let sharedItemID = UUID()
    let cloudItem = Item(
        id: sharedItemID,
        itemTypeID: type.id,
        fields: type.fields.map { field in
            FieldValue(fieldID: field.id, value: field.type == .richText ? .rich([Span("Cloud")]) : .text("Cloud"))
        },
        deckID: sharedDeckID
    )
    _ = try await cloud.repository.createItem(cloudItem, asOf: .now)
    let cloudAdapter = SQLiteLibrarySyncAdapter(repository: cloud.repository)
    let localAdapter = SQLiteLibrarySyncAdapter(repository: local.repository)
    let remote = try await cloudAdapter.encode(
        changes: try await cloud.repository.changes(after: 0, limit: 1_000),
        deviceID: "cloud"
    )

    _ = try await localAdapter.initialMerge(remote: remote, deviceID: "local")
    let summaries = try await local.repository.deckSummaries(asOf: .now)
    let remappedDeck = try #require(summaries.first(where: { $0.name == "Cloud deck" }))
    #expect(remappedDeck.id != sharedDeckID)
    let imported = try #require(try await local.repository.items(scope: .allDecks, sort: .createdAscending, search: "").first(where: { $0.title.contains("Cloud") }))
    #expect(imported.id == sharedItemID)
    #expect((try await local.repository.item(id: imported.id))?.item.deckID == remappedDeck.id)

    _ = try await localAdapter.initialMerge(remote: remote, deviceID: "local")
    #expect(try await local.repository.deckSummaries(asOf: .now).filter { $0.name == "Cloud deck" }.count == 1)
}

@Test func sqliteSyncAdapterReplicatesCardStateAndImmutableReview() async throws {
    let source = try await makeSyncRepository()
    let destination = try await makeSyncRepository()
    let type = try #require(try await source.repository.loadItemTypes().itemTypes.first)
    let item = Item(
        itemTypeID: type.id,
        fields: type.fields.map { field in
            FieldValue(fieldID: field.id, value: field.type == .richText ? .rich([Span("Value")]) : .text("Value"))
        }
    )
    _ = try await source.repository.createItem(item, asOf: .now)
    let card = try #require(try await source.repository.cards().first(where: { $0.itemID == item.id }))
    let submission = try await source.repository.submitReview(cardID: card.id, rating: .good, asOf: .now, durationMilliseconds: 800)

    let sourceAdapter = SQLiteLibrarySyncAdapter(repository: source.repository)
    let destinationAdapter = SQLiteLibrarySyncAdapter(repository: destination.repository)
    let records = try await sourceAdapter.encode(
        changes: try await source.repository.changes(after: 0, limit: 1_000),
        deviceID: "source"
    )
    try await destinationAdapter.applyRemote(records, origin: .cloud)

    let destinationCard = try await destination.repository.card(id: card.id)
    let sourceCard = try await source.repository.card(id: card.id)
    #expect(destinationCard.memory == sourceCard.memory)
    #expect(try await destination.repository.reviewLog(id: submission.reviewLogID).rating == .good)
}

@Test func syncMetadataStagesAssetsAcrossRestartAndCleansAfterCommit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-sync-staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("cloud-temp.png")
    let data = Data("durable asset".utf8)
    try data.write(to: source)
    let store = SyncMetadataStore(directory: directory.appendingPathComponent("metadata"))
    let envelope = SyncRecordEnvelope(
        id: "asset",
        resourceKind: "media",
        revision: 1,
        deviceID: "cloud",
        order: 1,
        isTombstone: false,
        payload: Data(),
        asset: SyncAssetDescriptor(hash: "hash", byteSize: Int64(data.count), signature: "hash", fileExtension: "png", contentType: "image"),
        stagedFileURL: source
    )
    let staged = try await store.stageAssets(in: [envelope])
    try await store.save(SyncMetadata(stagedInbound: staged))
    try FileManager.default.removeItem(at: source)

    let recovered = try await store.load().stagedInbound
    let durableURL = try #require(recovered.first?.stagedFileURL)
    #expect(try Data(contentsOf: durableURL) == data)
    await store.removeStagedAssets(in: recovered)
    #expect(!FileManager.default.fileExists(atPath: durableURL.path))
}

@Test func sqliteSyncAdapterReplicatesExtendedResourceKinds() async throws {
    let source = try await makeSyncRepository()
    let destination = try await makeSyncRepository()
    let type = try #require(try await source.repository.loadItemTypes().itemTypes.first)
    let deck = try await source.repository.createDeck(Deck(name: "Policy deck"))
    let mapping = PortableItemTypeMappingRecord(
        originLibraryID: UUID(),
        originTypeID: UUID(),
        schemaDigest: String(repeating: "a", count: 64),
        localTypeID: type.id
    )
    let policy = ItemTypeMembershipRecord.policy(
        deckID: deck.id,
        itemTypeID: type.id,
        ordinal: 0,
        isDefault: true
    )
    try await source.repository.applySynchronizedBatch([
        .itemTypeMembership(policy),
        .portableTypeMapping(mapping),
    ])
    try await source.repository.setStudyDayRolloverMinutes(5 * 60)

    let item = Item(
        itemTypeID: type.id,
        fields: type.fields.map { field in
            FieldValue(fieldID: field.id, value: field.type == .richText ? .rich([Span("Value")]) : .text("Value"))
        },
        deckID: deck.id
    )
    _ = try await source.repository.createItem(item, asOf: .now)
    let card = try #require(try await source.repository.cards().first(where: { $0.itemID == item.id }))
    let review = try await source.repository.submitReview(cardID: card.id, rating: .good, asOf: .now, durationMilliseconds: 10)
    try await source.repository.revertReview(id: review.reviewLogID, asOf: .now)

    let sourceAdapter = SQLiteLibrarySyncAdapter(repository: source.repository)
    let destinationAdapter = SQLiteLibrarySyncAdapter(repository: destination.repository)
    let envelopes = try await sourceAdapter.encode(
        changes: try await source.repository.changes(after: 0, limit: 1_000),
        deviceID: "source"
    )
    let kinds = Set(envelopes.map(\.resourceKind))
    #expect(kinds.contains("reviewRevert"))
    #expect(kinds.contains("itemTypeMembership"))
    #expect(kinds.contains("schedulingSettings"))
    #expect(kinds.contains("portableTypeMapping"))
    try await destinationAdapter.applyRemote(envelopes, origin: .cloud)

    #expect(try await destination.repository.itemTypeMembershipRecord(id: policy.id) == policy)
    #expect(try await destination.repository.portableItemTypeMappingRecord(id: mapping.id) == mapping)
    #expect(try await destination.repository.studyDayRolloverMinutes() == 5 * 60)
    let destinationRevertChanges = try await destination.repository.changes(after: 0, limit: 1_000)
    let revertID = try #require(destinationRevertChanges.last(where: { $0.resourceType == "reviewRevert" })?.resourceID)
    #expect(try await destination.repository.reviewRevertRecord(id: UUID(uuidString: revertID)!).reviewLogID == review.reviewLogID)
}

@Test func synchronizedBatchRollsBackAllResourcesWhenValidationFails() async throws {
    let fixture = try await makeSyncRepository()
    let deck = Deck(name: "Must roll back")
    let invalidItem = Item(itemTypeID: UUID(), fields: [])
    await #expect(throws: (any Error).self) {
        try await fixture.repository.applySynchronizedBatch([
            .deck(deck),
            .item(invalidItem, createdAt: .now, updatedAt: .now),
        ])
    }
    await #expect(throws: (any Error).self) {
        try await fixture.repository.deck(id: deck.id)
    }
}

@Test func initialMergeHonorsLegacyTypeAliasesAcrossRestartAndIncrementalEdits() async throws {
    let local = try await makeSyncRepository()
    let cloud = try await makeSyncRepository()
    let localBase = try #require(try await local.repository.loadItemTypes().itemTypes.first)
    let cloudBase = try #require(try await cloud.repository.loadItemTypes().itemTypes.first)
    let localType = ItemType(id: UUID(), name: "Shared schema", fields: localBase.fields, templates: localBase.templates)
    let cloudType = ItemType(id: UUID(), name: "Shared schema", fields: cloudBase.fields, templates: cloudBase.templates)
    _ = try await local.repository.createItemType(localType)
    _ = try await cloud.repository.createItemType(cloudType)
    let cloudItem = Item(
        itemTypeID: cloudType.id,
        fields: cloudType.fields.map { field in
            FieldValue(fieldID: field.id, value: field.type == .richText ? .rich([Span("Cloud")]) : .text("Cloud"))
        }
    )
    _ = try await cloud.repository.createItem(cloudItem, asOf: .now)
    let cloudID = try await cloud.repository.libraryID()
    let localID = try await local.repository.libraryID()
    let cloudAdapter = SQLiteLibrarySyncAdapter(repository: cloud.repository)
    let localAdapter = SQLiteLibrarySyncAdapter(repository: local.repository)
    let remote = try await cloudAdapter.encode(
        changes: try await cloud.repository.changes(after: 0, limit: 1_000),
        deviceID: "cloud"
    )

    // Reproduce the persisted alias left by an earlier merge implementation.
    try await local.repository.recordSyncItemTypeAlias(remoteID: cloudType.id, localID: localType.id)
    _ = try await localAdapter.initialMerge(remote: remote, deviceID: "local")
    #expect(try await local.repository.libraryAliases(canonicalID: localID).contains(cloudID))
    #expect(try await local.repository.item(id: cloudItem.id)?.item.itemTypeID == localType.id)
    #expect(!(try await local.repository.loadItemTypes().itemTypes.contains(where: { $0.id == cloudType.id })))
    #expect(try await local.repository.syncItemTypeAliases()[cloudType.id] == localType.id)
    let cursor = try await cloud.repository.changes(after: 0, limit: 1_000).last!.cursor
    let edited = Item(
        id: cloudItem.id, itemTypeID: cloudType.id,
        fields: cloudType.fields.map { field in
            FieldValue(fieldID: field.id, value: field.type == .richText ? .rich([Span("Edited remotely")]) : .text("Edited remotely"))
        }
    )
    _ = try await cloud.repository.updateItem(edited, asOf: .now)
    let incremental = try await cloudAdapter.encode(
        changes: cloud.repository.changes(after: cursor, limit: 1_000), deviceID: "cloud"
    )
    let restarted = SQLiteLibrarySyncAdapter(repository: local.repository)
    try await restarted.applyRemote(incremental, origin: .cloud)
    let received = try #require(try await local.repository.item(id: cloudItem.id))
    #expect(received.item.itemTypeID == localType.id)
    #expect(received.item.fields == edited.fields)
}

private struct SyncRepositoryFixture {
    let repository: SQLiteLibraryRepository
    let directory: URL
}

private func makeSyncRepository() async throws -> SyncRepositoryFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-sync-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await repository.bootstrap()
    return SyncRepositoryFixture(repository: repository, directory: directory)
}

@Test func conflictWithIdenticalItemContentDoesNotCreateADuplicate() async throws {
    let fixture = try await makeSyncRepository()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let type = try #require(try await fixture.repository.loadItemTypes().itemTypes.first)
    let item = Item(itemTypeID: type.id, fields: type.fields.map { .init(fieldID: $0.id, value: .text("Same content")) })
    _ = try await fixture.repository.createItem(item)
    let adapter = SQLiteLibrarySyncAdapter(repository: fixture.repository)
    let records = try await adapter.encode(changes: fixture.repository.changes(after: 0, limit: 1_000), deviceID: "local")
    let record = try #require(records.first { $0.resourceKind == "item" && $0.id == item.id.uuidString })
    let copy = SyncConflictCopy(resourceKind: "item", originalResourceID: item.id.uuidString, sourceDeviceID: "local", payload: record.payload)
    let before = try await fixture.repository.currentChangeCursor()
    try await adapter.restoreConflictCopy(copy)
    #expect(try await fixture.repository.currentChangeCursor() == before)
    #expect(try await fixture.repository.item(id: copy.id) == nil)
    #expect(try await fixture.repository.item(id: item.id)?.item == item)
}

@Test(arguments: [false, true])
func synchronizedFirstReviewsConsumeDailyAllowance(legacyPayload: Bool) async throws {
    let source = try await makeSyncRepository(), destination = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: source.directory)
        try? FileManager.default.removeItem(at: destination.directory)
    }
    let now = Date.now
    let deck = try await source.repository.createDeck(Deck(name: "Two per day", newCardsPerDay: 2))
    for index in 0..<3 {
        _ = try await source.repository.createItem(Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Card \(index)")),
                .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
            ], deckID: deck.id
        ), asOf: now)
    }
    let cards = try await source.repository.dueCards(scope: .allDecks, asOf: now)
    for card in cards {
        _ = try await source.repository.submitReview(cardID: card.id, rating: .easy, asOf: now, durationMilliseconds: 1000)
    }
    let adapter = SQLiteLibrarySyncAdapter(repository: source.repository)
    let encoded = try await adapter.initialMerge(remote: [], deviceID: "source")
    let records = try encoded.map { record in
        guard legacyPayload, record.resourceKind == "review" else { return record }
        var object = try #require(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        var review = try #require(object["review"] as? [String: Any])
        var value = try #require(review["_0"] as? [String: Any])
        value.removeValue(forKey: "introductionContext")
        review["_0"] = value
        object["review"] = review
        return SyncRecordEnvelope(
            id: record.id, resourceKind: record.resourceKind, revision: record.revision,
            deviceID: record.deviceID, order: record.order, isTombstone: false,
            payload: try JSONSerialization.data(withJSONObject: object)
        )
    }
    let receiver = SQLiteLibrarySyncAdapter(repository: destination.repository)
    try await receiver.applyRemote(records, origin: .cloud)
    // Re-delivery must not consume the allowance twice or restore it.
    try await receiver.applyRemote(records, origin: .cloud)
    let summary = try await destination.repository.scopeSummary(scope: .allDecks, asOf: now)
    #expect(summary.dueNow == 0)
    #expect(summary.newCount == 1)
    #expect(summary.hiddenNewCount == 1)
    #expect(summary == (try await source.repository.scopeSummary(scope: .allDecks, asOf: now)))
    // Undo on the source restores the same capacity on the other device.
    let review = try #require(records.first { $0.resourceKind == "review" })
    try await source.repository.revertReview(id: UUID(uuidString: review.id)!, asOf: now)
    let revertRecords = try await adapter.encode(
        changes: source.repository.changes(after: 0, limit: 1000), deviceID: "source"
    )
    try await receiver.applyRemote(revertRecords, origin: .cloud)
    #expect(try await destination.repository.scopeSummary(scope: .allDecks, asOf: now).availableNewCount == 1)
}

@Test func synchronizedQuotaKeepsOriginalDeckAfterCardMoves() async throws {
    let source = try await makeSyncRepository(), destination = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: source.directory)
        try? FileManager.default.removeItem(at: destination.directory)
    }
    let now = Date.now
    let original = try await source.repository.createDeck(Deck(name: "Original", newCardsPerDay: 1))
    let moved = try await source.repository.createDeck(Deck(name: "Moved"))
    for index in 0..<2 {
        _ = try await source.repository.createItem(Item(
            itemTypeID: BuiltInItemTypes.basicID,
            fields: [
                .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Card \(index)")),
                .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
            ], deckID: original.id
        ), asOf: now)
    }
    let card = try #require(try await source.repository.dueCards(scope: .allDecks, asOf: now).first)
    _ = try await source.repository.submitReview(cardID: card.id, rating: .easy, asOf: now, durationMilliseconds: 1000)
    var item = try #require(try await source.repository.item(id: card.item.id)?.item)
    item.deckID = moved.id
    _ = try await source.repository.updateItem(item, asOf: now)
    let records = try await SQLiteLibrarySyncAdapter(repository: source.repository).initialMerge(remote: [], deviceID: "source")
    try await SQLiteLibrarySyncAdapter(repository: destination.repository).applyRemote(records, origin: .cloud)
    #expect(try await destination.repository.scopeSummary(scope: .deck(original.id), asOf: now).availableNewCount == 0)
}

@Test func synchronizedUnassignedFirstReviewDoesNotConsumeALaterDeckAllowance() async throws {
    let source = try await makeSyncRepository(), destination = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: source.directory)
        try? FileManager.default.removeItem(at: destination.directory)
    }
    let now = Date.now
    let deck = try await source.repository.createDeck(Deck(name: "Limited", newCardsPerDay: 1))
    var item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Unassigned review")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
    ])
    _ = try await source.repository.createItem(item, asOf: now)
    let card = try #require(try await source.repository.dueCards(scope: .allDecks, asOf: now).first)
    _ = try await source.repository.submitReview(cardID: card.id, rating: .easy, asOf: now, durationMilliseconds: 1000)
    item.deckID = deck.id
    _ = try await source.repository.updateItem(item, asOf: now)
    _ = try await source.repository.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Still available")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
    ], deckID: deck.id), asOf: now)
    let records = try await SQLiteLibrarySyncAdapter(repository: source.repository).initialMerge(remote: [], deviceID: "source")
    try await SQLiteLibrarySyncAdapter(repository: destination.repository).applyRemote(records, origin: .cloud)
    #expect(try await destination.repository.scopeSummary(scope: .allDecks, asOf: now).availableNewCount == 1)
}


@Test func imageOcclusionSyncRoundTripKeepsCardGroupsAndMediaReferences() async throws {
    let source = try await makeSyncRepository(), destination = try await makeSyncRepository()
    defer {
        try? FileManager.default.removeItem(at: source.directory)
        try? FileManager.default.removeItem(at: destination.directory)
    }
    let type = try ItemTypeStudioDraft.newImageOcclusion().candidateItemType()
    _ = try await source.repository.createItemType(type)
    let image = try await source.repository.reserveMedia(data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), kind: .image, altText: "Diagram", asOf: .now).reference
    var content = ImageOcclusionContent(image: image)
    content.addMask(rect: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.2))
    content.addMask(rect: .init(x: 0.6, y: 0.5, width: 0.2, height: 0.3))
    let item = Item(itemTypeID: type.id, fields: [.init(fieldID: type.fields[0].id, value: .imageOcclusion(content))])
    _ = try await source.repository.createItem(item, asOf: .now)
    let records = try await SQLiteLibrarySyncAdapter(repository: source.repository).initialMerge(remote: [], deviceID: "source")
    #expect(records.contains { $0.resourceKind == "media" })
    _ = try await SQLiteLibrarySyncAdapter(repository: destination.repository).initialMerge(remote: records, deviceID: "destination")
    let restored = try #require(try await destination.repository.item(id: item.id))
    #expect(restored.item.fields == item.fields)
    let cards = try await destination.repository.cards().filter { $0.itemID == item.id }
    #expect(Set(cards.compactMap(\.occlusionGroup)) == [1, 2])
    #expect(cards.allSatisfy { $0.clozeGroup == nil })
}

@Test func imageOcclusionStarterAndDraftValidationAreConsistent() throws {
    let draft = ItemTypeStudioDraft.newImageOcclusion()
    #expect(draft.isValid)
    let type = try draft.candidateItemType()
    #expect(type.templates[0].interaction == .imageOcclusion)
    let visual = try CardSetupStarter.visual.makeCardSetup(fields: draft.fields)
    #expect(visual.interaction == .imageOcclusion)
    #expect(type.fields[0].isRequired)
    #expect(!ItemEditorState.canSave(ItemEditorState.empty(for: type), itemType: type))
}
