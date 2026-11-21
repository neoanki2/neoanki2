import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing
import SQLite3

private enum InjectedPublicationFailure: Error { case failed }
private actor FailingNativeBadgePublisher: AppIconBadgePublishing {
    private var failing = false
    func failNextUpdates() { failing = true }
    func publish(_ badge: AppIconBadge) throws {
        if failing { throw InjectedPublicationFailure.failed }
    }
}

@Suite @MainActor struct NativeLibraryWorkflowTests {
    @Test func committedImportRecoversItsReceiptWithoutRepeatingWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-workflow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let data = Data(#"{"itemType":"Basic","rows":[{"Front":"One","Back":"Answer"},{"Front":"Two","Back":"Answer"}]}"#.utf8)
        let context = NativeCommandContext(operation: "import", input: data)
        let outcome: CommandOutcome<Int> = try await NativeLibraryCommands.perform(on: repository, context: context) {
            _ = try await repository.importItems(data, format: .json, itemTypeID: nil,
                destinationDeckID: nil, context: ImportContext(), asOf: .now)
            // Simulates refresh/publication failing after the durable commit.
            throw InjectedPublicationFailure.failed
        }
        #expect(outcome.receipt?.affectedCount == 2)
        #expect(outcome.warnings.count == 1)
        let recovered: CommandOutcome<Int> = try await NativeLibraryCommands.perform(on: repository, context: context) {
            Issue.record("A committed command must never execute again")
            return 0
        }
        #expect(recovered.receipt == outcome.receipt)
        #expect(try await repository.items(scope: .allDecks, sort: .createdAscending, search: "").count == 2)
    }

    @Test func homeDemandDoesNotPopulateBrowseAndSelectionRejectsMissingRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-demand-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let model = LibraryFeatureModel(library: repository)
        await model.bootstrap()
        let type = try #require(model.itemTypes.first { $0.id == BuiltInItemTypes.basicID })
        try await model.createItem(itemType: type, deckID: nil, values: [
            BuiltInItemTypes.frontFieldID: .text("Question"), BuiltInItemTypes.backFieldID: .text("Answer"),
        ])
        await model.awaitReadModels()
        #expect(model.items.isEmpty)
        #expect(model.allDecksSummary.itemCount == 1)
        let rows = try await model.loadBrowse(scope: .allDecks)
        #expect(rows.count == 1)
        #expect(throws: (any Error).self) { try NativeLibraryCommands.selection([UUID()], rows: rows) }
        let deck = try await repository.createDeck(Deck(name: "Scoped"))
        try await model.createItem(itemType: type, deckID: deck.id, values: [
            BuiltInItemTypes.frontFieldID: .text("Scoped question"), BuiltInItemTypes.backFieldID: .text("Answer"),
        ])
        _ = try await model.loadBrowse(scope: .deck(deck.id))
        await model.refresh()
        #expect(model.items.count == 1)
        #expect(model.items.first?.deckID == deck.id)
        model.selectedScope = .unassigned
        try await model.reload()
        #expect(model.items.count == 1)
        #expect(model.items.first?.deckID == nil)
        let snapshot = try await NativeLibraryReadCoordinator(library: repository)
            .load(scope: .unassigned, demand: [.summary], asOf: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.items == nil)
        #expect(snapshot.catalog == nil)
        #expect(snapshot.home == nil)
        #expect(snapshot.sourceRevision != nil)
        #expect(snapshot.scope == .unassigned)
    }
    @Test(.timeLimit(.minutes(2)))
    func mediaWritesKeepProjectionRevisionWhileMediaStillReachesSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let reads = NativeLibraryReadCoordinator(library: repository)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = try await reads.load(scope: .allDecks, demand: [], asOf: now)
        let journalBaseline = try await repository.currentChangeCursor()
        let syncStream = await repository.changeNotifications()
        let projectionStream = await reads.invalidations()
        var syncEvents = syncStream.makeAsyncIterator()
        var projectionEvents = projectionStream.makeAsyncIterator()

        for sample in UInt8(0)..<8 {
            let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, sample])
            _ = try await repository.reserveMedia(data: png, kind: .image, altText: "Fixture", asOf: now)
        }
        let syncedMediaCursor = try #require(await syncEvents.next())
        #expect(syncedMediaCursor > journalBaseline)
        let mediaEvents = try await repository.changes(after: journalBaseline, limit: 100)
        #expect(mediaEvents.count == 8)
        #expect(mediaEvents.allSatisfy { $0.resourceType == "media" })
        let afterMedia = try await reads.load(scope: .allDecks, demand: [], asOf: now)
        #expect(afterMedia.sourceRevision == initial.sourceRevision)

        _ = try await repository.createDeck(Deck(name: "Course"))
        let deckCursor = try await repository.currentChangeCursor()
        #expect(await projectionEvents.next() == deckCursor)
        let afterDeck = try await reads.load(scope: .allDecks, demand: [], asOf: now)
        #expect(afterDeck.sourceRevision == deckCursor)
    }

    @Test func damagedMaturityDoesNotPreventNativeBrowsingOrStudy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try ItemStore(databaseURL: url)
        let repository = SQLiteLibraryRepository(store: store)
        try await repository.bootstrap()
        let data = Data(#"{"itemType":"Basic","rows":[{"Front":"One","Back":"Answer"}]}"#.utf8)
        _ = try await repository.importJSONItems(from: data, itemTypeID: nil, context: ImportContext(), asOf: .now)
        let card = try #require(try await store.cards().first)
        _ = try await store.submitReview(cardID: card.id, rating: .good)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE review_logs SET log = '{}';", nil, nil, nil) == SQLITE_OK)
        let snapshot = try await NativeLibraryReadCoordinator(library: repository)
            .load(scope: .allDecks, demand: [.home, .browse], asOf: .now)
        #expect(snapshot.maturityIssue != nil)
        #expect(snapshot.home?.allDecksSummary.itemCount == 1)
        #expect(snapshot.items?.count == 1)
        #expect(try await repository.dueCards(scope: .allDecks, asOf: .distantFuture, limit: 1).count == 1)
        // The HTTP/application contract keeps its existing failure semantics.
        await #expect(throws: MaturityReadError.self) { try await repository.scopeSummary(scope: .allDecks, asOf: .now) }
    }

    @Test func portableImportRecoversExactResultAcrossConnections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-portable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ItemStore(databaseURL: root.appendingPathComponent("source.sqlite"))
        try await source.bootstrap()
        let deck = try await source.createDeck(Deck(name: "Source"))
        _ = try await source.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: deck.id))
        let package = root.appendingPathComponent("source.neodeck")
        try await PortableDeck.export(deckID: deck.id, from: source, to: package)
        let targetURL = root.appendingPathComponent("target.sqlite")
        let repository = try SQLiteLibraryRepository(databaseURL: targetURL)
        try await repository.bootstrap()
        let context = NativeCommandContext(operation: "portable-import", input: Data(package.path.utf8))
        let imported = try await NativeLibraryCommands.importDeck(on: repository, source: package,
            authored: false, context: context)
        let reopened = try SQLiteLibraryRepository(databaseURL: targetURL)
        let recovered = try await NativeLibraryCommands.importDeck(on: reopened, source: package,
            authored: false, context: context)
        #expect(recovered == imported)
        #expect(try await repository.items(scope: .allDecks, sort: .createdAscending, search: "").count == 1)
    }

    @Test func devicePublicationFailureKeepsTheSavedCommandSuccessful() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-device-warning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let badge = FailingNativeBadgePublisher()
        let model = LibraryFeatureModel(library: repository, badgePublisher: badge)
        await model.bootstrap()
        let type = try #require(model.itemTypes.first { $0.id == BuiltInItemTypes.basicID })
        await badge.failNextUpdates()
        try await model.createItem(itemType: type, deckID: nil, values: [
            BuiltInItemTypes.frontFieldID: .text("Question"), BuiltInItemTypes.backFieldID: .text("Answer"),
        ])
        await model.awaitDevicePublication()
        #expect(model.lastCommandReceipt != nil)
        #expect(model.recoveryMessage?.contains("Device updates could not finish") == true)
        #expect(try await repository.scopeSummary(scope: .allDecks, asOf: .now).itemCount == 1)
    }

}
