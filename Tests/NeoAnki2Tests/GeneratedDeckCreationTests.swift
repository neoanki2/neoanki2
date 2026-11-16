import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import ProseDeckBuilder
import SwiftUI
import SQLite3
import Testing

@Suite @MainActor struct GeneratedDeckCreationTests {
    @Test(arguments: [false, true])
    func typedAndCompatibilityImportsHaveSameContentAndOrder(prose: Bool) async throws {
        let root = generatedTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = Deck(name: "Parent", newCardsPerDay: 7)
        let creation = try makeCreation(parent: parent.id, prose: prose)
        let bundle = try creation.materialize(using: SystemDeckBuildWorkspaceProvider())
        defer { bundle.cleanup() }
        let typed = try ItemStore(databaseURL: root.appendingPathComponent("typed.sqlite"))
        let legacy = try ItemStore(databaseURL: root.appendingPathComponent("legacy.sqlite"))
        for store in [typed, legacy] { try await store.bootstrap(); _ = try await store.createDeck(parent) }
        let typedResult = try await AuthoredDeck.importPrepared(creation.prepared, into: typed, parentDeckID: parent.id)
        let legacyResult = try await AuthoredDeck.importDeck(from: bundle.bundleURL, into: legacy, parentDeckID: parent.id)
        #expect(typedResult.itemCount == legacyResult.itemCount)
        let typedRoot = try await typed.deck(id: #require(typedResult.deckIDs.first))
        let legacyRoot = try await legacy.deck(id: #require(legacyResult.deckIDs.first))
        #expect(typedRoot.parentID == parent.id)
        #expect(legacyRoot.parentID == parent.id)
        #expect(try await typed.deck(id: parent.id).newCardsPerDay == 7)
        let typedContent = try await contentSnapshot(typed)
        let legacyContent = try await contentSnapshot(legacy)
        #expect(typedContent == legacyContent)
        // A second intentional creation reuses the same semantic schema.
        let again = try await AuthoredDeck.importPrepared(creation.prepared, into: typed, parentDeckID: parent.id)
        #expect(again.createdItemTypeCount == 0)
        #expect(again.reusedItemTypeCount == 1)
        #expect(again.deckIDs != typedResult.deckIDs)
    }

    @Test func missingParentAndMidImportFailureLeaveNoPartialCreation() async throws {
        let root = generatedTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try ItemStore(databaseURL: url)
        try await store.bootstrap()
        let parent = Deck(name: "Parent")
        _ = try await store.createDeck(parent)
        let creation = try makeCreation(parent: parent.id)
        _ = try await store.deleteDeck(id: parent.id)
        let repository = SQLiteLibraryRepository(store: store)
        do {
            _ = try await NativeLibraryCommands.createGeneratedDeck(on: repository,
                prepared: creation.prepared, parentDeckID: parent.id, context: creation.command)
            Issue.record("Deleted parent must reject creation")
        } catch { #expect(error is DatabaseError) }
        #expect(try await store.listDecks().isEmpty)
        #expect(try await store.listItems().isEmpty)
        #expect(try await store.nativeCommandReceipt(creation.command) == nil)
        _ = try await store.createDeck(parent)
        let cursor = try await repository.currentChangeCursor()
        try generatedExecute("""
            CREATE TRIGGER fail_generated_second BEFORE INSERT ON items
            WHEN (SELECT COUNT(*) FROM items) >= 1 BEGIN SELECT RAISE(ABORT, 'injected second item'); END;
            """, at: url)
        do {
            _ = try await NativeLibraryCommands.createGeneratedDeck(on: repository,
                prepared: creation.prepared, parentDeckID: parent.id, context: creation.command)
            Issue.record("Injected failure must reject the entire transaction")
        } catch { #expect(error is DatabaseError) }
        #expect(try await store.listDecks() == [parent])
        #expect(try await store.listItems().isEmpty)
        #expect(try await repository.currentChangeCursor() == cursor)
        #expect(try await store.nativeCommandReceipt(creation.command) == nil)
    }

    @Test func lostResponseAndRestartRecoverOneExactCommittedResult() async throws {
        let root = generatedTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let repository = try SQLiteLibraryRepository(databaseURL: url)
        try await repository.bootstrap()
        let parent = try await repository.createDeck(Deck(name: "Parent"))
        let creation = try makeCreation(parent: parent.id)
        let lost = LostGeneratedResponse(repository: repository)
        let recovered = try await NativeLibraryCommands.createGeneratedDeck(on: lost,
            prepared: creation.prepared, parentDeckID: parent.id, context: creation.command)
        #expect(recovered.warnings.count == 1)
        let reopened = try SQLiteLibraryRepository(databaseURL: url)
        let replay = try await NativeLibraryCommands.createGeneratedDeck(on: reopened,
            prepared: creation.prepared, parentDeckID: parent.id, context: creation.command)
        #expect(replay.result == recovered.result)
        #expect(try await reopened.items(scope: .allDecks, sort: .createdAscending, search: "").count == creation.prepared.itemCount)
        #expect(try await reopened.deckSummaries(asOf: .now).count == 2)
        #expect(await lost.writeCount == 1)
        let conflicting = NativeCommandContext(id: creation.command.id, operation: "create-generated-deck", input: Data("different".utf8))
        do {
            _ = try await NativeLibraryCommands.createGeneratedDeck(on: reopened,
                prepared: creation.prepared, parentDeckID: parent.id, context: conflicting)
            Issue.record("An operation ID must not be reused for different content")
        } catch { #expect(error is DatabaseError) }
    }

    @Test func cancellationBeforeCommitLeavesNoDeckOrReceipt() async throws {
        let root = generatedTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let parent = try await repository.createDeck(Deck(name: "Parent"))
        let creation = try makeCreation(parent: parent.id)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativeLibraryCommands.createGeneratedDeck(on: repository,
                prepared: creation.prepared, parentDeckID: parent.id, context: creation.command)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled creation must not commit") }
        catch { #expect(error is CancellationError) }
        #expect(try await repository.deckSummaries(asOf: .now).count == 1)
        #expect(try await repository.nativeCommandReceipt(creation.command) == nil)
    }

    @Test func compatibilityWriterDoesNotFollowPreexistingSymlinks() throws {
        let root = generatedTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Generated.neoanki")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("preserved".utf8).write(to: sentinel)
        let items = bundle.appendingPathComponent("items")
        try FileManager.default.createSymbolicLink(at: items, withDestinationURL: outside)
        let creation = try makeCreation(parent: UUID())
        #expect(throws: (any Error).self) { try AuthoredDeck.write(creation.prepared, to: bundle) }
        #expect(try Data(contentsOf: sentinel) == Data("preserved".utf8))
        try FileManager.default.removeItem(at: items)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent(AuthoredDeck.manifestName),
                                                 withDestinationURL: sentinel)
        try AuthoredDeck.write(creation.prepared, to: bundle)
        #expect(try Data(contentsOf: sentinel) == Data("preserved".utf8))
        #expect(AuthoredDeck.validate(at: bundle).isEmpty)
    }

    @Test func registryPrefersTypedFactoryAndPreservesLegacyFallback() throws {
        let creation = try makeCreation(parent: UUID())
        let context = DeckBuilderHostContext(rootDecks: [])
        let descriptor = DeckBuilderDescriptor(id: "test", title: "Test", subtitle: "", systemImage: "book")
        var legacyCalls = 0
        var typedCalls = 0
        let feature = AnyDeckBuilderFeature(descriptor: descriptor) { _, _, _ in
            legacyCalls += 1
            return EmptyView()
        }.withPreparedView { _, callback, _ in
            typedCalls += 1
            callback(creation)
            return EmptyView()
        }
        var observed: UUID?
        _ = feature.makeCreationView(context: context, onPrepared: { observed = $0.command.id },
            onGenerated: { _ in Issue.record("Native creation must not export a bundle") }, onCancel: {})
        #expect(typedCalls == 1 && legacyCalls == 0)
        #expect(observed == creation.command.id)
        _ = feature.makeView(context: context, onGenerated: { _ in }, onCancel: {})
        #expect(legacyCalls == 1)
        let oldFeature = AnyDeckBuilderFeature(descriptor: descriptor) { _, _, _ in
            legacyCalls += 1
            return EmptyView()
        }
        _ = oldFeature.makeCreationView(context: context, onPrepared: { _ in Issue.record("Unexpected typed factory") },
            onGenerated: { _ in }, onCancel: {})
        #expect(legacyCalls == 2)
    }

    @Test func typedCreationEnforcesEncodedAndContentLimitsBeforePersistence() throws {
        let parent = UUID()
        let limits: [AuthoredDeckLimits] = [
            .init(maximumSourceBytes: 10), .init(maximumTotalSourceBytes: 50),
            .init(maximumLineBytes: 10), .init(maximumParts: 0),
            .init(portable: .init(maximumItems: 1)),
        ]
        for limit in limits {
            #expect(throws: PoemDeckBuilderError.self) {
                try PoemDeckGenerator.prepare(input: .init(destinationDeckID: parent, author: "A", title: "T", text: "one\ntwo\nthree"), limits: limit)
            }
        }
    }
}

private enum GeneratedTestFailure: Error { case lost, unused }
private actor LostGeneratedResponse: LibraryGeneratedDeckCreating, LibraryNativeCommandSupporting {
    let repository: SQLiteLibraryRepository
    var writeCount = 0
    init(repository: SQLiteLibraryRepository) { self.repository = repository }
    func createGeneratedDeck(_ prepared: PreparedAuthoredDeck, parentDeckID: UUID) async throws -> PortableDeckImportResult {
        _ = try await repository.createGeneratedDeck(prepared, parentDeckID: parentDeckID)
        writeCount += 1
        throw GeneratedTestFailure.lost
    }
    func createGeneratedDeck(from source: URL, parentDeckID: UUID) async throws -> PortableDeckImportResult { throw GeneratedTestFailure.unused }
    func nativeCommandReceipt(_ context: NativeCommandContext) async throws -> NativeCommandReceipt? { try await repository.nativeCommandReceipt(context) }
    func moveItems(_ selection: [ItemMoveSelection], to deckID: UUID?) async throws -> Int { throw GeneratedTestFailure.unused }
    func importItems(_ data: Data, format: NativeImportFormat, itemTypeID: UUID?, destinationDeckID: UUID?, context: ImportContext, asOf: Date) async throws -> [SavedItemSummary] { throw GeneratedTestFailure.unused }
    func deleteItemsAtomically(_ ids: Set<UUID>, asOf: Date) async throws -> Int { throw GeneratedTestFailure.unused }
}

private func makeCreation(parent: UUID, prose: Bool = false) throws -> GeneratedDeckCreation {
    if prose {
        return try ProseDeckGenerator.prepare(input: .init(destinationDeckID: parent, author: "Ліна", title: "Title", text: "First sentence. Second sentence.\n\nAnother paragraph."))
    }
    return try PoemDeckGenerator.prepare(input: .init(destinationDeckID: parent, author: "Ліна", title: "Title", text: "one é\ntwo\n\nthree"))
}

private func contentSnapshot(_ store: ItemStore) async throws -> [[String]] {
    let due = try await store.fetchDueCards(asOf: .now)
    var result: [[String]] = []
    for row in due {
        let loaded = try #require(await store.fetchItem(id: row.card.itemID))
        result.append(try [loaded.itemType.portableSchemaDigest()] + loaded.itemType.fields.map {
            String(describing: loaded.item.value(for: $0.id))
        } + loaded.item.tags.sorted())
    }
    return result
}

private func generatedTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("typed-generation-\(UUID())")
}

private func generatedExecute(_ sql: String, at url: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw GeneratedTestFailure.unused }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw GeneratedTestFailure.unused }
}
