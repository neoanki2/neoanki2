@testable import NeoAnkiCloudSync
import CloudKit
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing
import os

private actor ConflictBacklogTransport: CloudSyncTransport {
    private let metadata: SyncMetadataStore
    private let serverRecords: [CKRecord]
    private let buffers = TransportBuffers()
    private static let zone = CKRecordZone.ID(zoneName: "SyncTest")
    private(set) var matchedCount = 0

    init(metadata: SyncMetadataStore, serverCards: [SyncRecordEnvelope]) {
        self.metadata = metadata
        serverRecords = serverCards.map { record in
            CKSyncEngineTransport.record(from: record, id: CKSyncEngineTransport.recordID(for: record, in: Self.zone))
        }
    }

    func start() async throws { await buffers.remember(serverRecords) }
    func stop() async {}
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] { [] }

    func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        let result = try await CKSyncEngineTransport.prepareOutgoing(records, in: Self.zone,
            buffers: buffers, metadataStore: metadata)
        matchedCount += result.matched.count
    }
}

struct LibraryZoneChangeFetcherTests {
    private func record(_ id: String) -> SyncRecordEnvelope {
        .init(id: id, resourceKind: "card", revision: 1, deviceID: "phone", order: 1,
              isTombstone: false, payload: Data(id.utf8))
    }

    @Test func idleIncrementalReadDoesNotRewriteMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let store = SyncMetadataStore(directory: root) { data, file in
            try data.write(to: file, options: .atomic)
            writes.withLock { $0 += 1 }
        }
        try await store.save(SyncMetadata(libraryZoneChangeToken: Data([1]), didCompleteInitialMerge: true))
        let result = try await LibraryZoneChangeFetcher(metadataStore: store).fetch(persistEmptyFinalPage: false) { token in
            #expect(token == Data([1]))
            return .init(records: [], token: Data([2]), moreComing: false)
        }
        #expect(result.isEmpty)
        #expect(writes.withLock { $0 } == 1)
        #expect(try await store.load().libraryZoneChangeToken == Data([1]))
    }

    @Test func explicitReadRunsWithoutPushHintsAndResumesAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        let first = record("first"), second = record("second")
        let stale = try await store.load()
        let delivered = try await LibraryZoneChangeFetcher(metadataStore: store).fetch { token in
            if token == nil {
                return .init(records: [first], token: Data([1]), moreComing: true)
            }
            #expect(token == Data([1]))
            // The first page is durable before asking the server for page two.
            let durable = try await store.load()
            #expect(durable.stagedInbound == [first])
            return .init(records: [second], token: Data([2]), moreComing: false)
        }
        #expect(delivered == [first, second])
        try await store.save(stale)
        let committed = try await store.completeIncoming([first], metadata: stale)
        #expect(committed.libraryZoneChangeToken == Data([2]))
        #expect(committed.stagedInbound == [second])
        let restarted = SyncMetadataStore(directory: root)
        _ = try await LibraryZoneChangeFetcher(metadataStore: restarted).fetch { token in
            #expect(token == Data([2]))
            return .init(records: [], token: Data([3]), moreComing: false)
        }
        #expect(try await restarted.load().libraryZoneChangeToken == Data([3]))
        #expect(try await restarted.load().stagedInbound == [second])
    }

    @Test func failedPageKeepsLastDurableTokenAndInbox() async throws {
        enum Failure: Error { case network }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        let first = record("first")
        await #expect(throws: Failure.self) {
            _ = try await LibraryZoneChangeFetcher(metadataStore: store).fetch { token in
                if token == nil {
                    return .init(records: [first], token: Data([1]), moreComing: true)
                }
                throw Failure.network
            }
        }
        #expect(try await store.load().libraryZoneChangeToken == Data([1]))
        #expect(try await store.load().stagedInbound == [first])
        try await store.resetLibraryZoneChangeToken()
        #expect(try await store.load().libraryZoneChangeToken == nil)
        #expect(try await store.load().stagedInbound == [first])
    }

    @Test func failedAssetStagingCannotAdvanceToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        try await store.receiveZonePage([], token: Data([1]))
        let asset = SyncAssetDescriptor(hash: "missing", byteSize: 1, signature: "missing",
                                        fileExtension: "png", contentType: "image")
        let missing = SyncRecordEnvelope(id: "missing", resourceKind: "media", revision: 1,
            deviceID: "phone", order: 1, isTombstone: false, payload: Data(), asset: asset,
            stagedFileURL: root.appendingPathComponent("does-not-exist"))
        await #expect(throws: (any Error).self) {
            _ = try await LibraryZoneChangeFetcher(metadataStore: store).fetch { _ in
                .init(records: [missing], token: Data([2]), moreComing: false)
            }
        }
        #expect(try await store.load().libraryZoneChangeToken == Data([1]))
        #expect(try await store.load().stagedInbound.isEmpty)
    }

    @Test func missedPhoneReviewsReduceMacDueCountFrom66To1() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let phone = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("phone.sqlite"))
        let mac = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("mac.sqlite"))
        try await phone.bootstrap()
        try await mac.bootstrap()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<66 {
            _ = try await phone.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
                .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Card \(index)")),
                .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
            ]), asOf: now)
        }
        let sender = SQLiteLibrarySyncAdapter(repository: phone)
        let receiver = SQLiteLibrarySyncAdapter(repository: mac)
        try await receiver.applyRemote(sender.initialMerge(remote: [], deviceID: "phone"), origin: .cloud)
        let cursor = try await phone.currentChangeCursor()
        let cards = try await phone.dueCards(scope: .allDecks, asOf: now)
        for card in cards.prefix(65) {
            _ = try await phone.submitReview(cardID: card.id, rating: .easy, asOf: now,
                                              durationMilliseconds: 1000)
        }
        #expect(try await phone.dueCount(scope: .allDecks, asOf: now) == 1)
        #expect(try await mac.dueCount(scope: .allDecks, asOf: now) == 66)
        let changes = try await sender.encode(changes: phone.changes(after: cursor, limit: 1000), deviceID: "phone")
        let store = SyncMetadataStore(directory: root.appendingPathComponent("sync"))
        _ = try await LibraryZoneChangeFetcher(metadataStore: store).fetch { token in
            #expect(token == nil)
            return .init(records: changes, token: Data([1]), moreComing: false)
        }
        // A restart after fetching still recovers every schedule and review.
        let recovered = try await SyncMetadataStore(directory: root.appendingPathComponent("sync")).load()
        try await receiver.applyRemote(recovered.stagedInbound, origin: .cloud)
        #expect(try await mac.dueCount(scope: .allDecks, asOf: now) == 1)
        #expect(try await mac.cards() == phone.cards())
    }

    @Test func downloadedReviewsApplyWithinTheConflictBacklogWriteBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mac = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("mac.sqlite"))
        let phone = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("phone.sqlite"))
        try await mac.bootstrap()
        try await phone.bootstrap()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let dueCount = 61
        let conflictCount = 213
        for index in 0..<(dueCount + conflictCount) {
            _ = try await mac.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
                .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Card \(index)")),
                .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
            ]), asOf: index < dueCount ? now : now.addingTimeInterval(86_400))
        }
        let sender = SQLiteLibrarySyncAdapter(repository: mac)
        let receiver = SQLiteLibrarySyncAdapter(repository: phone)
        let baseline = try await sender.initialMerge(remote: [], deviceID: "mac")
        try await receiver.applyRemote(baseline, origin: .cloud)
        let cursor = try await mac.currentChangeCursor()
        let dueCards = try await mac.dueCards(scope: .allDecks, asOf: now)
        let remainingCard = try #require(dueCards.last)
        let dueIDs = Set(dueCards.map { $0.id.uuidString })
        let conflicts = baseline.filter { $0.resourceKind == "card" && !dueIDs.contains($0.id) }
        try #require(conflicts.count == conflictCount)
        for card in dueCards.dropLast() {
            _ = try await mac.submitReview(cardID: card.id, rating: .easy, asOf: now, durationMilliseconds: 1000)
        }
        let downloaded = try await sender.encode(changes: mac.changes(after: cursor, limit: 1000), deviceID: "mac")
        let reviewIDs = Set(downloaded.filter { $0.resourceKind == "review" }.map(\.id))
        try #require(reviewIDs.count == dueCount - 1)

        // Resume a prior upload with divergent scheduling provenance on
        // future cards. The reviews for due cards are already downloaded.
        let phoneParameters = UUID(), macParameters = UUID()
        let pending = try conflicts.map { try withSchedulingProvenance($0, device: "phone", parameterSet: phoneParameters) }
        let serverCards = try conflicts.map { try withSchedulingProvenance($0, device: "mac", parameterSet: macParameters) }
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let store = SyncMetadataStore(directory: root.appendingPathComponent("sync")) { data, file in
            try data.write(to: file, options: .atomic)
            writes.withLock { $0 += 1 }
        }
        try await store.save(SyncMetadata(
            outboundCursor: phone.currentChangeCursor(), pendingOutbound: pending,
            serverBaseline: Dictionary(uniqueKeysWithValues: conflicts.map { ("card:\($0.id)", $0) }),
            didCreateInitialBackup: true, didCompleteInitialMerge: true
        ))
        let token = Data([1])
        try await store.receiveZonePage(downloaded, token: token)
        let transport = ConflictBacklogTransport(metadata: store, serverCards: serverCards)
        let service = OfflineFirstSyncService(repository: phone, adapter: receiver,
            transport: transport, metadataStore: store, backupURL: { root.appendingPathComponent("backup.sqlite") })

        try #require(try await phone.dueSnapshot(activeScope: .allDecks, asOf: now).total == dueCount)
        let initialWrites = writes.withLock { $0 }
        await service.synchronize()
        let syncWrites = writes.withLock { $0 } - initialWrites
        #expect(syncWrites <= 8, "SYNC_CONFLICT_WRITE_BUDGET: \(syncWrites) full metadata writes for \(conflictCount) conflicts")
        #expect(await transport.matchedCount == conflictCount)
        #expect(try await mac.dueCards(scope: .allDecks, asOf: now).map(\.id) == [remainingCard.id])
        #expect(try await phone.dueCards(scope: .allDecks, asOf: now).map(\.id) == [remainingCard.id])
        #expect(try await phone.dueSnapshot(activeScope: .allDecks, asOf: now).total == 1)
        let appliedReviewIDs = Set(try await phone.resourceRevisionSnapshot()
            .filter { $0.resourceType == "review" && !$0.isDeleted }.map(\.resourceID))
        #expect(appliedReviewIDs == reviewIDs)
        let settled = try await store.load()
        #expect(settled.libraryZoneChangeToken == token)
        #expect(settled.stagedInbound.isEmpty)
        #expect(settled.pendingOutbound?.isEmpty == true)
        #expect(settled.issues.isEmpty)
        #expect(settled.resolvedConflictCopies?.count == conflictCount)
    }

    private func withSchedulingProvenance(
        _ record: SyncRecordEnvelope, device: String, parameterSet: UUID
    ) throws -> SyncRecordEnvelope {
        var payload = try #require(JSONSerialization.jsonObject(with: record.payload) as? [String: [String: [String: Any]]])
        payload["card"]?["_0"]?["memoryParameterSetID"] = parameterSet.uuidString
        return .init(id: record.id, resourceKind: record.resourceKind, revision: record.revision + 1,
            deviceID: device, order: record.order, isTombstone: false,
            payload: try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys))
    }
}

private actor PausedLibraryOperations: IncrementalLibraryTransport {
    private let metadata: SyncMetadataStore
    private var page: [SyncRecordEnvelope]
    private var upload: CheckedContinuation<Void, Never>?
    private var asset: CheckedContinuation<Void, Never>?
    private var uploadObserver: CheckedContinuation<Void, Never>?
    private var assetObserver: CheckedContinuation<Void, Never>?
    private var activity: CheckedContinuation<Void, Never>?
    private var activityObserver: CheckedContinuation<Void, Never>?
    private let holdActivity: Bool

    init(metadata: SyncMetadataStore, page: [SyncRecordEnvelope], holdActivity: Bool = false) {
        self.metadata = metadata
        self.page = page
        self.holdActivity = holdActivity
    }

    func start() async throws {}
    func stop() async { release() }
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        if holdActivity {
            await withCheckedContinuation { continuation in
                activity = continuation
                activityObserver?.resume()
                activityObserver = nil
            }
        }
        return []
    }
    func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        if holdActivity { return }
        await withCheckedContinuation { continuation in
            upload = continuation
            uploadObserver?.resume()
            uploadObserver = nil
        }
        try await metadata.acknowledge(records)
    }
    func enqueueMedia(_ record: SyncRecordEnvelope) async throws {}
    func confirmLibraryChanges(_ records: [SyncRecordEnvelope]) async throws -> [SyncRecordEnvelope] { records }

    func fetchLibraryChanges(didStagePage: @escaping @Sendable () async throws -> Void) async throws {
        guard !page.isEmpty else { return }
        let records = page
        page = []
        try await metadata.receiveZonePage(records, token: Data([1]))
        try await didStagePage()
    }

    func fetchMediaAsset(_ record: SyncRecordEnvelope) async throws -> SyncRecordEnvelope? {
        await withCheckedContinuation { continuation in
            asset = continuation
            assetObserver?.resume()
            assetObserver = nil
        }
        return nil
    }

    func waitForUpload() async {
        guard upload == nil else { return }
        await withCheckedContinuation { uploadObserver = $0 }
    }

    func waitForAsset() async {
        guard asset == nil else { return }
        await withCheckedContinuation { assetObserver = $0 }
    }

    func waitForActivity() async {
        guard activity == nil else { return }
        await withCheckedContinuation { activityObserver = $0 }
    }

    func release() {
        upload?.resume()
        upload = nil
        asset?.resume()
        asset = nil
        activity?.resume()
        activity = nil
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func libraryReviewsApplyWhileUploadMediaAndStatisticsAreSuspended(missingDependency: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let phone = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("phone.sqlite"))
    let mac = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("mac.sqlite"))
    try await phone.bootstrap()
    try await mac.bootstrap()
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let item = Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Prompt")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer"))
    ])
    _ = try await phone.createItem(item, asOf: now)
    let sender = SQLiteLibrarySyncAdapter(repository: phone)
    let receiver = SQLiteLibrarySyncAdapter(repository: mac)
    let baseline = try await sender.initialMerge(remote: [], deviceID: "phone")
    try await receiver.applyRemote(baseline, origin: .cloud)
    let cursor = try await phone.currentChangeCursor()
    let cards = try await phone.cards()
    let card = try #require(cards.first)
    let review = try await phone.submitReview(cardID: card.id, rating: .easy, asOf: now, durationMilliseconds: 1000)
    var changes = try await sender.encode(changes: phone.changes(after: cursor, limit: 1000), deviceID: "phone")
    if missingDependency {
        let orphanedDeck = Deck(name: "Parent still in transit", parentID: UUID())
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(orphanedDeck))
        let payload = try JSONSerialization.data(withJSONObject: ["deck": ["_0": encoded]])
        changes.append(.init(id: orphanedDeck.id.uuidString, resourceKind: "deck", revision: 1,
            deviceID: "phone", order: 1, isTombstone: false, payload: payload))
    }
    let media = SyncRecordEnvelope(id: "asset", resourceKind: "media", revision: 1, deviceID: "phone", order: 1,
        isTombstone: false, payload: Data(), asset: .init(hash: "asset", byteSize: 1,
            signature: "asset", fileExtension: "png", contentType: "image"))
    let metadata = SyncMetadataStore(directory: root.appendingPathComponent("sync"))
    try await metadata.save(SyncMetadata(outboundCursor: mac.currentChangeCursor(),
        serverBaseline: Dictionary(uniqueKeysWithValues: baseline.map { ($0.syncKey, $0) }),
        didCreateInitialBackup: true, didCompleteInitialMerge: true))
    _ = try await mac.createDeck(Deck(name: "Only on the receiver"))
    let transport = PausedLibraryOperations(metadata: metadata, page: changes + [media])
    let statisticsMetadata = SyncMetadataStore(directory: root.appendingPathComponent("statistics"))
    let heldStatistics = PausedLibraryOperations(metadata: statisticsMetadata, page: [], holdActivity: true)
    let statistics = StatisticsSyncService(repository: mac, transport: heldStatistics, metadataStore: statisticsMetadata)
    let service = OfflineFirstSyncService(repository: mac, adapter: receiver, transport: transport,
        metadataStore: metadata, statistics: statistics, backupURL: { root.appendingPathComponent("backup.sqlite") })
    let syncing = Task { await service.synchronize() }
    await transport.waitForUpload()
    await transport.waitForAsset()
    await heldStatistics.waitForActivity()
    _ = await service.receiveRemoteChanges(.library)

    #expect(try await mac.synchronizedReviewRecord(id: review.reviewLogID) == phone.synchronizedReviewRecord(id: review.reviewLogID))
    #expect(try await mac.dueSnapshot(activeScope: .allDecks, asOf: now).total == 0)
    let whilePaused = try await metadata.load()
    #expect(whilePaused.stagedInbound.contains(media))
    #expect(!whilePaused.stagedInbound.contains { $0.resourceKind == "review" })
    #expect(whilePaused.stagedInbound.contains { $0.resourceKind == "deck" } == missingDependency)
    #expect(whilePaused.pendingOutbound?.contains { $0.resourceKind == "deck" } == true)

    await service.stop()
    await syncing.value
}
