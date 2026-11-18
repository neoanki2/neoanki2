import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation
import Testing
@testable import NeoAnki2

private actor ChangingSyncService: SyncService {
    private var value: SyncStatus = .offline
    private var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdsNextStatusRead = false
    private var heldStatusRead: CheckedContinuation<SyncStatus, Never>?
    private var statusReadWaiters: [CheckedContinuation<Void, Never>] = []

    func libraryChanges() async -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changeObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeChangeObserver(id) } }
        return stream
    }
    func committedIncomingChanges() async {
        for observer in changeObservers.values { observer.yield(()) }
    }
    private func removeChangeObserver(_ id: UUID) {
        changeObservers.removeValue(forKey: id)
        guard changeObservers.isEmpty else { return }
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func waitUntilChangeStreamTerminates() async {
        guard !changeObservers.isEmpty else { return }
        await withCheckedContinuation { terminationWaiters.append($0) }
    }
    func start() async {}
    func synchronize() async {}
    func stop() async {}
    func status() async -> SyncStatus {
        guard holdsNextStatusRead else { return value }
        holdsNextStatusRead = false
        // Deliberately ignore cancellation: callers must reject a completed
        // read from an obsolete service generation even if it cannot be stopped.
        return await withCheckedContinuation { continuation in
            heldStatusRead = continuation
            let waiters = statusReadWaiters
            statusReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    func issues() async -> [SyncIssue] { [] }
    func setStatus(_ status: SyncStatus) { value = status }
    func holdNextStatusRead() { holdsNextStatusRead = true }
    func waitUntilStatusReadIsHeld() async {
        guard heldStatusRead == nil else { return }
        await withCheckedContinuation { statusReadWaiters.append($0) }
    }
    func releaseStatusRead(returning status: SyncStatus) {
        heldStatusRead?.resume(returning: status)
        heldStatusRead = nil
    }
}

@MainActor @Observable
private final class SyncRefreshProbe {
    var sources: [String] = []
}

@MainActor
@Test func macIncomingReviewRefreshesCountsAndBrowseRowsWithoutTheTimer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
    try await repository.bootstrap()
    let now = Date.now
    let item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Incoming review")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
    ])
    _ = try await repository.createItem(item, asOf: now)
    let items = ItemsModel(library: repository, mediaStore: nil)
    let decks = DecksModel(library: repository)
    await items.load(asOf: now)
    await decks.load(asOf: now)
    #expect(items.dueCount == 1)
    #expect(decks.allDecksDueCount == 1)
    let service = ChangingSyncService()
    // A long status interval makes the commit event the only refresh trigger.
    let status = MacCloudSyncStatusModel(interval: .seconds(3_600))
    defer { status.stop() }
    let refreshed = SyncRefreshProbe()
    await status.observe(service) {
        await decks.refreshCounts(asOf: now)
        await items.refreshAfterSync(asOf: now)
        refreshed.sources.append("incoming")
    }
    let card = try #require(try await repository.cards().first { $0.itemID == item.id })
    _ = try await repository.submitReview(cardID: card.id, rating: .easy, asOf: now, durationMilliseconds: 700)
    await service.committedIncomingChanges()
    try await waitForObservedCondition { !refreshed.sources.isEmpty }
    #expect(refreshed.sources == ["incoming"])
    #expect(items.dueCount == 0)
    #expect(decks.allDecksDueCount == 0)
    #expect(items.items == (try await repository.items(scope: .allDecks, sort: .createdAscending)))
}

@MainActor
private func waitForStatus(_ status: SyncStatus, in model: MacCloudSyncStatusModel) async throws {
    try await waitForObservedCondition { model.status == status }
    #expect(model.status == status)
}

@MainActor
@Test func macSyncSettingsRecoversFromOfflineWithoutManualSync() async throws {
    let service = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .milliseconds(5))
    defer { model.stop() }
    await model.observe(service)
    #expect(model.status == .offline)
    await service.setStatus(.syncing)
    try await waitForStatus(.syncing, in: model)
    let current = SyncStatus.current(lastSync: Date(timeIntervalSince1970: 100))
    await service.setStatus(current)
    try await waitForStatus(current, in: model)
    await service.setStatus(.needsAttention(issueCount: 1))
    try await waitForStatus(.needsAttention(issueCount: 1), in: model)
}

@MainActor
@Test func disablingMacSyncStopsOldStatusUpdates() async throws {
    let service = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .seconds(3_600))
    defer { model.stop() }
    await service.setStatus(.syncing)
    await model.observe(service)
    try await waitForStatus(.syncing, in: model)
    await service.holdNextStatusRead()
    let obsoleteRefresh = Task { await model.refresh() }
    await service.waitUntilStatusReadIsHeld()
    model.stop()
    let current = SyncStatus.current(lastSync: .now)
    await service.setStatus(current)
    await service.releaseStatusRead(returning: current)
    await obsoleteRefresh.value
    #expect(model.status == .offline)
}

@MainActor
@Test func replacingMacSyncServiceDoesNotDisplayOldServiceStatus() async throws {
    let old = ChangingSyncService()
    let replacement = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .seconds(3_600))
    defer { model.stop() }
    await old.setStatus(.syncing)
    await model.observe(old)
    try await waitForStatus(.syncing, in: model)
    await old.holdNextStatusRead()
    let obsoleteRefresh = Task { await model.refresh() }
    await old.waitUntilStatusReadIsHeld()
    await replacement.setStatus(.accountUnavailable)
    await model.observe(replacement)
    try await waitForStatus(.accountUnavailable, in: model)
    let oldCurrent = SyncStatus.current(lastSync: .now)
    await old.setStatus(oldCurrent)
    await old.releaseStatusRead(returning: oldCurrent)
    await obsoleteRefresh.value
    #expect(model.status == .accountUnavailable)
}

@MainActor
@Test func replacingMacSyncServiceStopsItsOldLibraryRefreshes() async throws {
    let old = ChangingSyncService(), replacement = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .seconds(3_600))
    defer { model.stop() }
    let refreshed = SyncRefreshProbe()
    await model.observe(old) { refreshed.sources.append("old") }
    await model.observe(replacement) { refreshed.sources.append("replacement") }
    // Cancellation acknowledgment proves the old consumer has terminated;
    // no arbitrary delay can establish this negative assertion.
    await old.waitUntilChangeStreamTerminates()
    await old.committedIncomingChanges()
    await replacement.committedIncomingChanges()
    try await waitForObservedCondition { !refreshed.sources.isEmpty }
    #expect(refreshed.sources == ["replacement"])
}
