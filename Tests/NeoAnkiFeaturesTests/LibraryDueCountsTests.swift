import Foundation
import NeoAnkiApplication
import NeoAnkiCore
@testable import NeoAnkiFeatures
import Observation
import Testing

private actor HeldDueReader: LibraryDueSnapshotReading {
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var value = 0
    var fails = false
    func configure(value: Int, hold: Bool = false, fails: Bool = false) {
        self.value = value; self.shouldHold = hold; self.fails = fails
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { held?.resume(); held = nil }
    func dueSnapshot(activeScope: DeckScope?, asOf: Date) async throws -> LibraryDueSnapshot {
        calls += 1
        let captured = value
        let fails = fails
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation {
                held = $0; observer?.resume(); observer = nil
            }
        }
        if fails { throw DatabaseError.queryFailed("Availability fixture failed") }
        return LibraryDueSnapshot(total: captured, unassigned: captured, decks: [:],
            activeScope: activeScope, activeScopeCount: captured, sourceRevision: Int64(calls),
            calculatedAt: asOf, validUntil: asOf.addingTimeInterval(3600))
    }
}

private actor DueBoundaryGate {
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var deadline: Date?
    func sleep(until date: Date) async {
        deadline = date
        await withCheckedContinuation { held = $0; observer?.resume(); observer = nil }
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { held?.resume(); held = nil }
}

private actor DueWidgetRecorder: WidgetSnapshotPublishing {
    private(set) var latest: DueWidgetSnapshot?
    func publish(_ snapshot: DueWidgetSnapshot) { latest = snapshot }
}

@Suite @MainActor struct LibraryDueCountsTests {
    private func fixture() throws -> (URL, SQLiteLibraryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("due-model-\(UUID())")
        return (root, try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite")))
    }

    @Test func foregroundHidesOldZeroAndCoalescesRequestsWithoutPublishingObsoleteResults() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = HeldDueReader()
        let counts = LibraryDueCountsModel(library: repository, reader: reader)
        var published: [Int] = []
        counts.onSnapshot = { published.append($0.total) }
        await counts.open()
        #expect(counts.count(for: .allDecks) == 0)
        await reader.configure(value: 0, hold: true)
        counts.setForeground(true)
        #expect(counts.state == .checking)
        #expect(counts.count(for: .allDecks) == nil)
        await reader.waitUntilHeld()
        for _ in 0..<100 { counts.invalidate() }
        let deck = DeckScope.deck(UUID())
        counts.selectScope(deck)
        await reader.configure(value: 32)
        await reader.release()
        await counts.waitUntilSettled()
        #expect(await reader.calls == 3, "One initial read, one held read, and one coalesced successor")
        #expect(published == [0, 32])
        #expect(counts.count(for: deck) == 32)
        counts.setForeground(false)
    }

    @Test func failureKeepsUnknownRatherThanZeroAndRetryRecovers() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = HeldDueReader()
        let counts = LibraryDueCountsModel(library: repository, reader: reader)
        await counts.open()
        await reader.configure(value: 32, fails: true)
        await counts.refresh()
        guard case let .failed(message) = counts.state else { Issue.record("Expected an availability error"); return }
        #expect(message.contains("Availability fixture failed"))
        #expect(counts.count(for: .allDecks) == nil)
        await reader.configure(value: 32)
        await counts.refresh()
        #expect(counts.count(for: .allDecks) == 32)
    }

    @Test func schedulesTheKnownBoundaryAndStopsWhenBackgrounded() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = HeldDueReader()
        let boundary = DueBoundaryGate()
        let counts = LibraryDueCountsModel(library: repository, reader: reader)
        counts.sleepUntil = { await boundary.sleep(until: $0) }
        counts.setForeground(true)
        await counts.open()
        await boundary.waitUntilHeld()
        #expect(await boundary.deadline == counts.snapshot?.validUntil)
        await reader.configure(value: 32)
        let publication = AsyncStream<Void>.makeStream()
        counts.onSnapshot = { _ in publication.continuation.yield(()) }
        await boundary.release()
        var iterator = publication.stream.makeAsyncIterator()
        await iterator.next()
        await counts.waitUntilSettled()
        #expect(counts.count(for: .allDecks) == 32)
        await boundary.waitUntilHeld()
        counts.setForeground(false)
        let calls = await reader.calls
        await boundary.release()
        await counts.waitUntilSettled()
        #expect(await reader.calls == calls)
        #expect(counts.state == .checking)
    }

    @Test func oldHomeSnapshotCannotReplaceFreshCountsAndCommitInvalidatesImmediately() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = HeldNativeLibraryReads(base: repository, observesChanges: true)
        let model = LibraryFeatureModel(library: repository, reads: NativeLibraryReadCoordinator(library: reads))
        await model.bootstrap(startSync: false)
        let now = Date.now
        let future = now.addingTimeInterval(3600)
        let revision = model.libraryRevision
        _ = try await repository.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Future")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]), asOf: future)
        while model.libraryRevision == revision {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.libraryRevision } onChange: { continuation.resume() }
            }
        }
        await model.awaitReadModels()
        await model.dueCounts.refresh(asOf: now)
        #expect(model.dueCounts.count(for: .allDecks) == 0)
        let gate = await reads.arm(offsets: [1])[0]
        let slow = Task { try await model.reload(asOf: now) }
        await reads.waitUntilHeld(gate)
        await model.dueCounts.refresh(asOf: future)
        #expect(model.dueCounts.state == .ready)
        #expect(model.dueCounts.count(for: .allDecks) == 1)
        await reads.release(gate)
        try await slow.value
        #expect(model.allDecksSummary.dueNow == 0)
        #expect(model.dueCounts.count(for: .allDecks) == 1, "A later full-read completion must not replace the fast projection")
        model.requestRefreshAfterCommit()
        #expect(model.dueCounts.state == .checking)
        await model.awaitReadModels()
    }

    @Test func cancelledRefreshDoesNotScheduleWork() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = HeldDueReader()
        let counts = LibraryDueCountsModel(library: repository, reader: reader)
        await counts.open()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await counts.refresh()
        }
        await task.value
        #expect(await reader.calls == 1)
        #expect(counts.state == .ready)
    }

    @Test func commitsDuringInitialHomeLoadingRefreshAvailabilityBeforeReady() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = HeldNativeLibraryReads(base: repository, observesChanges: true)
        let gate = await reads.arm(offsets: [1])[0]
        let model = LibraryFeatureModel(library: repository, reads: NativeLibraryReadCoordinator(library: reads))
        let opening = Task { await model.bootstrap(startSync: false) }
        await reads.waitUntilHeld(gate)
        let revision = model.libraryRevision
        _ = try await repository.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Committed during startup")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]))
        while model.libraryRevision == revision {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.libraryRevision } onChange: { continuation.resume() }
            }
        }
        await model.dueCounts.waitUntilSettled()
        #expect(model.loadState == .loading)
        #expect(model.dueCounts.count(for: .allDecks) == 1)
        await reads.release(gate)
        await opening.value
        #expect(model.loadState == .ready)
        #expect(model.dueCounts.count(for: .allDecks) == 1)
        await model.awaitDevicePublication()
    }

    @Test func widgetKeepsScopedFamilyCountsAndDoesNotMistakeCacheExpiryForNextStudyTime() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repository.bootstrap()
        let first = try await repository.createDeck(Deck(name: "A"))
        let second = try await repository.createDeck(Deck(name: "B"))
        let widget = DueWidgetRecorder()
        let model = LibraryFeatureModel(library: repository, widgetPublisher: widget)
        await model.bootstrap(startSync: false)
        await model.awaitDevicePublication()
        #expect(await widget.latest?.nextDueAt == nil, "A conservative cache rollover is not a scheduled card")
        let json = "{\"format\":\"neoanki-context-example\",\"target\":{\"language\":\"en\",\"expression\":\"same family\"}}"
        for deck in [first, second] {
            try await model.createItem(itemType: BuiltInItemTypes.basic, deckID: deck.id, values: [
                BuiltInItemTypes.frontFieldID: .text(json), BuiltInItemTypes.backFieldID: .text("Answer"),
            ])
        }
        await model.awaitDevicePublication()
        #expect(model.dueCounts.deckCount(second.id) == 0, "Home uses the global representative")
        let scoped = await widget.latest?.decks.first { $0.id == second.id }
        #expect(scoped?.dueCount == 1, "The widget's deck link retains that deck's scoped study eligibility")
    }
}
