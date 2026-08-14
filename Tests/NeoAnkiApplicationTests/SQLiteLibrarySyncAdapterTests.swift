import Foundation
import NeoAnkiApplication
import NeoAnkiCloudSync
import NeoAnkiCore
import Testing

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

@Test func initialMergeAliasesLibrariesAndDeduplicatesEquivalentItemTypeSchemas() async throws {
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

    _ = try await localAdapter.initialMerge(remote: remote, deviceID: "local")
    #expect(try await local.repository.libraryAliases(canonicalID: localID).contains(cloudID))
    #expect(try await local.repository.item(id: cloudItem.id)?.item.itemTypeID == localType.id)
    #expect(!(try await local.repository.loadItemTypes().itemTypes.contains(where: { $0.id == cloudType.id })))
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
