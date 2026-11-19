import Foundation
import NeoAnkiApplication
import NeoAnkiCore
@testable import NeoAnkiFeatures
import Observation
import Testing

actor OptionalPublicationGate: AppIconBadgePublishing, NotificationSchedulingService, WidgetSnapshotPublishing {
    enum Site: String, Sendable, CaseIterable { case badge, reminder, widget }
    private let site: Site
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var active = 0
    private(set) var maximumActive = 0

    init(_ site: Site) { self.site = site }
    func arm() { armed = true }
    private func effect(_ requested: Site) async {
        active += 1
        maximumActive = max(maximumActive, active)
        if armed, requested == site {
            armed = false
            await withCheckedContinuation { continuation in
                held = continuation
                observer?.resume(); observer = nil
            }
        }
        active -= 1
    }
    func publish(_ badge: AppIconBadge) async { await effect(.badge) }
    func publish(_ snapshot: DueWidgetSnapshot) async { await effect(.widget) }
    func replaceDailyReminder(_ request: DailyReminderRequest?) async { await effect(.reminder) }
    func authorizationStatus() -> NotificationAuthorizationStatus { .authorized }
    func requestAuthorization() -> Bool { true }
    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { held?.resume(); held = nil }
}

/// Holds completed home reads at publication, including an obsolete failure.
/// Writes still go through the real SQLite repository; only the read projection
/// is controlled, so a commit can occur while an older snapshot is suspended.
actor HeldNativeLibraryReads: LibraryBrowsing, LibraryNativeReadSupporting, LibraryChangePersisting {
    let base: SQLiteLibraryRepository
    private let observesChanges: Bool
    private var homeReadCount = 0
    private var heldIndices: Set<Int> = []
    private var failingIndices: Set<Int> = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [Int: CheckedContinuation<Void, Never>] = [:]
    var readCount: Int { homeReadCount }

    init(base: SQLiteLibraryRepository, observesChanges: Bool = false) {
        self.base = base; self.observesChanges = observesChanges
    }

    func changeNotifications() async -> AsyncStream<Int64> {
        if observesChanges { return await base.changeNotifications() }
        return AsyncStream { $0.finish() }
    }
    func currentChangeCursor() async throws -> Int64 {
        if observesChanges { return try await base.currentChangeCursor() }
        return 0
    }
    func changes(after cursor: Int64, limit: Int) async throws -> [LibraryChange] {
        try await base.changes(after: cursor, limit: limit)
    }
    func createBackup(at destination: URL) async throws { try await base.createBackup(at: destination) }
    func verifyBackup(at destination: URL) async throws { try await base.verifyBackup(at: destination) }

    func arm(offsets: [Int], firstFails: Bool = false) -> [Int] {
        let indices = offsets.map { homeReadCount + $0 }
        heldIndices.formUnion(indices)
        if firstFails, let first = indices.first { failingIndices.insert(first) }
        return indices
    }

    func waitUntilHeld(_ index: Int) async {
        guard held[index] == nil else { return }
        await withCheckedContinuation { observers[index] = $0 }
    }

    func release(_ index: Int) { held.removeValue(forKey: index)?.resume() }

    func nativeHomeSnapshot(scope: DeckScope, asOf: Date) async throws -> (ColdLibraryHomeSnapshot, String?) {
        homeReadCount += 1
        let index = homeReadCount
        let snapshot = try await base.nativeHomeSnapshot(scope: scope, asOf: asOf)
        if heldIndices.remove(index) != nil {
            await withCheckedContinuation { continuation in
                held[index] = continuation
                observers.removeValue(forKey: index)?.resume()
            }
        }
        if failingIndices.remove(index) != nil {
            throw DatabaseError.executeFailed("Obsolete held home read failed")
        }
        return snapshot
    }

    func nativeScopeSummary(scope: DeckScope, asOf: Date) async throws -> (ScopeSummary, String?) {
        try await base.nativeScopeSummary(scope: scope, asOf: asOf)
    }
    func libraryID() async throws -> UUID { try await base.libraryID() }
    func loadItemTypes() async throws -> ItemTypeLoadResult { try await base.loadItemTypes() }
    func loadItemTypeCatalog() async throws -> ItemTypeCatalog { try await base.loadItemTypeCatalog() }
    func authoringItemTypes(for deckID: UUID?) async throws -> AuthoringItemTypes {
        try await base.authoringItemTypes(for: deckID)
    }
    func effectiveItemTypePolicy(for deckID: UUID) async throws -> DeckItemTypePolicy? {
        try await base.effectiveItemTypePolicy(for: deckID)
    }
    func items(scope: DeckScope, sort: ItemSortOrder, search: String) async throws -> [SavedItemSummary] {
        try await base.items(scope: scope, sort: sort, search: search)
    }
    func item(id: UUID) async throws -> (item: Item, itemType: ItemType)? { try await base.item(id: id) }
    func itemBrowseSchedules(itemIDs: [UUID]) async throws -> [UUID: ItemBrowseSchedule] {
        try await base.itemBrowseSchedules(itemIDs: itemIDs)
    }
    func scopeSummary(scope: DeckScope, asOf: Date) async throws -> ScopeSummary {
        try await base.scopeSummary(scope: scope, asOf: asOf)
    }
    func itemRecordsPage(offset: Int, limit: Int) async throws -> [LibraryItemRecord] {
        try await base.itemRecordsPage(offset: offset, limit: limit)
    }
}

@Suite @MainActor struct NativeCommandCompletionTests {
    enum Command: String, CaseIterable {
        case create, edit, delete, move, deck, importItems

        var expectedItemCount: Int {
            switch self {
            case .delete: 0
            case .create, .importItems: 2
            case .edit, .move, .deck: 1
            }
        }
    }

    @Test(arguments: [false, true])
    func explicitBrowseReadSurvivesACommittedCommandsQueuedHomeRefresh(obsoleteReadFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reload-demand-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let controlledReads = HeldNativeLibraryReads(base: repository)
        let model = LibraryFeatureModel(library: repository, reads: NativeLibraryReadCoordinator(library: controlledReads))
        await model.bootstrap(startSync: false)
        await model.awaitDevicePublication()
        // Hold the explicit read, then the automatic read after the explicit
        // read's commit-invalidated snapshot has been retried once.
        let gates = await controlledReads.arm(offsets: [1, 3], firstFails: obsoleteReadFails)
        let explicit = Task { try await model.reload() }
        await controlledReads.waitUntilHeld(gates[0])
        try await model.createItem(itemType: BuiltInItemTypes.basic, deckID: nil, values: [
            BuiltInItemTypes.frontFieldID: .text("Committed while reading"),
            BuiltInItemTypes.backFieldID: .text("Answer"),
        ])
        while model.pendingReloadCount < 2 {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.pendingReloadCount } onChange: { continuation.resume() }
            }
        }
        #expect(model.isRefreshing)
        #expect(model.lastCommandReceipt != nil)
        await controlledReads.release(gates[0])
        await controlledReads.waitUntilHeld(gates[1])
        try await explicit.value
        // The explicit caller has its own requested rows and fresh home data
        // even while the separate queued refresh is still suspended.
        #expect(model.items.map(\.title) == ["Committed while reading"])
        #expect(model.allDecksSummary.itemCount == 1)
        #expect(model.pendingReloadCount == 1)
        #expect(model.isRefreshing)
        #expect(model.loadState == .ready)
        #expect(model.recoveryMessage == nil)
        await controlledReads.release(gates[1])
        await model.awaitDevicePublication()
        #expect(model.pendingReloadCount == 0)
        #expect(!model.isRefreshing)
    }

    @Test(arguments: [false, true])
    func newerUserScopeSupersedesAHeldReadWithoutPublishingItsFailure(obsoleteReadFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reload-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let deck = try await repository.createDeck(Deck(name: "Destination"))
        _ = try await repository.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Destination item")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: deck.id))
        let controlledReads = HeldNativeLibraryReads(base: repository)
        let model = LibraryFeatureModel(library: repository, reads: NativeLibraryReadCoordinator(library: controlledReads))
        await model.bootstrap(startSync: false)
        await model.awaitDevicePublication()
        let gates = await controlledReads.arm(offsets: [1], firstFails: obsoleteReadFails)
        model.selectedScope = .unassigned
        let oldRead = Task { await model.refresh() }
        await controlledReads.waitUntilHeld(gates[0])
        model.selectedScope = .deck(deck.id)
        let newRead = Task { try await model.reload() }
        while model.pendingReloadCount < 2 {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.pendingReloadCount } onChange: { continuation.resume() }
            }
        }
        await controlledReads.release(gates[0])
        await oldRead.value
        try await newRead.value
        #expect(model.items.map(\.title) == ["Destination item"])
        #expect(model.loadState == .ready)
        #expect(model.recoveryMessage == nil)
        await model.awaitDevicePublication()
        #expect(!model.isRefreshing)
    }

    @Test(arguments: Command.allCases, OptionalPublicationGate.Site.allCases)
    func nativeCommandsAcknowledgeCommitWhileOptionalEffectsAreHeld(command: Command, site: OptionalPublicationGate.Site) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let first = try await repository.createDeck(Deck(name: "First"))
        let destination = command == .move ? try await repository.createDeck(Deck(name: "Second")) : nil
        let item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Original")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: first.id)
        _ = try await repository.createItem(item)
        let effects = OptionalPublicationGate(site)
        let model = LibraryFeatureModel(library: repository, notifier: effects, widgetPublisher: effects, badgePublisher: effects)
        await model.bootstrap(startSync: false)
        await model.awaitDevicePublication()
        let rows = command == .move ? try await model.loadBrowse(scope: .allDecks) : []
        await effects.arm()
        var returned = false
        let operation = Task {
            switch command {
            case .create:
                try await model.createItem(itemType: BuiltInItemTypes.basic, deckID: first.id, values: [
                    BuiltInItemTypes.frontFieldID: .text("Created"), BuiltInItemTypes.backFieldID: .text("Answer"),
                ])
            case .edit:
                var edited = item; edited.fields[0].value = .text("Corrected")
                try await model.updateItem(edited)
            case .delete: try await model.deleteItems([item.id])
            case .move: try await model.moveItems([item.id], to: try #require(destination).id, rows: rows)
            case .deck: try await model.createDeck(name: "Created deck", parentID: nil, newCardsPerDay: nil)
            case .importItems:
                _ = try await model.importJSON(Data(#"{"itemType":"Basic","rows":[{"Front":"Imported","Back":"Answer"}]}"#.utf8), itemTypeID: nil, deckID: first.id)
            }
            returned = true
        }
        await effects.waitUntilHeld()
        // The journal observer may publish before receipt reconciliation ends.
        // Observe that essential boundary rather than assume task scheduling order.
        while model.lastCommandReceipt == nil {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.lastCommandReceipt } onChange: { continuation.resume() }
            }
        }
        #expect(returned, "EDITOR_COMMIT_BOUNDARY: \(command.rawValue) acknowledgement must not wait for \(site.rawValue)")
        // Read readiness remains available while the independent OS worker is held.
        await model.refresh()
        await model.awaitReadModels()
        #expect(!model.isRefreshing)
        #expect(model.allDecksSummary.itemCount == command.expectedItemCount)
        if returned {
            try await model.createDeck(name: "Another command", parentID: nil, newCardsPerDay: nil)
            await model.awaitReadModels()
            #expect(model.decks.contains { $0.name == "Another command" })
        }
        await effects.release()
        try await operation.value
        await model.awaitDevicePublication()
        #expect(await effects.maximumActive == 1)
    }

    @Test func bootstrapPublishesReadyContentWithoutWaitingForTheDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        let effects = OptionalPublicationGate(.badge)
        await effects.arm()
        let model = LibraryFeatureModel(library: repository, badgePublisher: effects)
        let bootstrap = Task { await model.bootstrap(startSync: false) }
        await effects.waitUntilHeld()
        #expect(model.loadState == .ready)
        #expect(!model.isRefreshing)
        await model.refresh()
        #expect(model.loadState == .ready)
        await effects.release()
        await bootstrap.value
        await model.awaitDevicePublication()
    }
}
