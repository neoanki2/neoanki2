import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
@testable import NeoAnki2

private actor ChangingSyncService: SyncService {
    private var value: SyncStatus = .offline
    let changes = SyncLibraryChanges()
    func libraryChanges() async -> AsyncStream<Void> { await changes.stream() }
    func committedIncomingChanges() async { await changes.publish() }
    func start() async {}
    func synchronize() async {}
    func stop() async {}
    func status() async -> SyncStatus { value }
    func issues() async -> [SyncIssue] { [] }
    func setStatus(_ status: SyncStatus) { value = status }
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
    var refreshed = false
    await status.observe(service) {
        await decks.refreshCounts(asOf: now)
        await items.refreshAfterSync(asOf: now)
        refreshed = true
    }
    let card = try #require(try await repository.cards().first { $0.itemID == item.id })
    _ = try await repository.submitReview(cardID: card.id, rating: .easy, asOf: now, durationMilliseconds: 700)
    await service.committedIncomingChanges()
    let deadline = ContinuousClock.now + .seconds(2)
    while !refreshed, ContinuousClock.now < deadline { await Task.yield() }
    #expect(refreshed)
    #expect(items.dueCount == 0)
    #expect(decks.allDecksDueCount == 0)
    #expect(items.items == (try await repository.items(scope: .allDecks, sort: .createdAscending)))
}

@MainActor
private func waitForStatus(_ status: SyncStatus, in model: MacCloudSyncStatusModel) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while model.status != status, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
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
    let model = MacCloudSyncStatusModel(interval: .milliseconds(5))
    await model.observe(service)
    await service.setStatus(.syncing)
    try await waitForStatus(.syncing, in: model)
    model.stop()
    await service.setStatus(.current(lastSync: .now))
    try await Task.sleep(for: .milliseconds(25))
    #expect(model.status == .offline)
}

@MainActor
@Test func replacingMacSyncServiceDoesNotDisplayOldServiceStatus() async throws {
    let old = ChangingSyncService()
    let replacement = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .milliseconds(5))
    defer { model.stop() }
    await model.observe(old)
    await old.setStatus(.syncing)
    try await waitForStatus(.syncing, in: model)
    await model.observe(replacement)
    await old.setStatus(.current(lastSync: .now))
    await replacement.setStatus(.accountUnavailable)
    try await waitForStatus(.accountUnavailable, in: model)
}

@MainActor
@Test func replacingMacSyncServiceStopsItsOldLibraryRefreshes() async throws {
    let old = ChangingSyncService(), replacement = ChangingSyncService()
    let model = MacCloudSyncStatusModel(interval: .seconds(3_600))
    defer { model.stop() }
    var refreshed: [String] = []
    await model.observe(old) { refreshed.append("old") }
    await model.observe(replacement) { refreshed.append("replacement") }
    await old.committedIncomingChanges()
    await replacement.committedIncomingChanges()
    let deadline = ContinuousClock.now + .seconds(2)
    while refreshed.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    #expect(refreshed == ["replacement"])
}
