import CloudKit
import Foundation
import NeoAnkiApplication
@testable import NeoAnkiCloudSync
import NeoAnkiCore
import Testing

/// Operation choices, input UUIDs, dates, faults, and delivery shuffles come
/// from the seed. Storage-generated history IDs are checked by identity,
/// never by their random ordering. No Apple account/device/network is used.
private struct SyncRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func index(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    mutating func uuid() -> UUID {
        let a = next(), b = next()
        let hex = String(format: "%016llx%016llx", a, b)
        let chars = Array(hex)
        return UUID(uuidString: [String(chars[0..<8]), String(chars[8..<12]),
            String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-"))!
    }
}

private func resourceKey(_ r: SyncRecordEnvelope) -> String { "\(r.resourceKind):\(r.id)" }

/// A server change tag is deliberately independent of local revision numbers.
/// The transport can lose an acknowledgement after committing a prefix of a
/// batch; retry must be idempotent and preserve the remainder across restart.
private actor TestCloud {
    struct Version: Sendable { var tag: Int; var record: SyncRecordEnvelope }
    var resources: [String: Version] = [:]
    var generation = 0
    func snapshot() -> [String: Version] { resources }
    func save(_ record: SyncRecordEnvelope, expected: Int?) -> SyncRecordEnvelope? {
        let key = resourceKey(record)
        if let old = resources[key] {
            if old.record.payload == record.payload && old.record.isTombstone == record.isTombstone {
                return nil
            }
            if old.tag != expected { return old.record }
        }
        generation += 1
        resources[key] = Version(tag: generation, record: record)
        return nil
    }
}

private actor FaultTransport: CloudSyncTransport {
    enum Fault { case none, start, fetch, beforeSend, afterPartialSend }
    let cloud: TestCloud
    let metadata: SyncMetadataStore
    var known: [String: TestCloud.Version] = [:]
    var writeTags: [String: Int] = [:]
    var inbound: [SyncRecordEnvelope] = []
    var fault: Fault = .none
    var random: SyncRandom
    var sent = 0
    init(cloud: TestCloud, seed: UInt64, metadata: SyncMetadataStore) { self.cloud = cloud; self.metadata = metadata; random = SyncRandom(state: seed) }
    func inject(_ value: Fault) { fault = value }
    private func networkError() -> NSError {
        NSError(domain: CKErrorDomain, code: CKError.Code.networkFailure.rawValue)
    }
    func start() async throws {
        if fault == .start { fault = .none; throw networkError() }
        await refresh()
    }
    func stop() async {}
    private func refresh() async {
        let snapshot = await cloud.snapshot()
        let changed = snapshot.filter { known[$0.key]?.tag != $0.value.tag }.map(\.value.record).sorted { resourceKey($0) < resourceKey($1) }
        inbound += changed.shuffled(using: &random)
        // Duplicate deliveries are legal, and must not create new history IDs.
        if let duplicate = changed.first { inbound.append(duplicate) }
        known = snapshot
        writeTags = snapshot.mapValues(\.tag)
    }
    func enqueue(_ records: [SyncRecordEnvelope]) async throws {
        if fault == .beforeSend { fault = .none; throw networkError() }
        let partial = fault == .afterPartialSend
        fault = .none
        for (index, record) in records.enumerated() {
            let prior = try await metadata.load().serverBaseline?[resourceKey(record)]
            let current = await cloud.snapshot()[resourceKey(record)]?.record
            if let prior, let current, !SyncMetadataStore.sameContent(prior, current),
               !SyncMetadataStore.sameContent(record, current) {
                if !SyncMetadataStore.sameContent(prior, record) {
                    try await metadata.preserveConflict(local: record, server: current)
                }
                try await metadata.receive([current])
                inbound.append(current)
                continue
            }
            let conflict = await cloud.save(record, expected: writeTags[resourceKey(record)])
            if let conflict {
                try await metadata.preserveConflict(local: record, server: conflict)
                try await metadata.receive([conflict]); inbound.append(conflict)
            } else {
                try await metadata.acknowledge([record])
                writeTags[resourceKey(record)] = await cloud.snapshot()[resourceKey(record)]?.tag
            }
            sent += 1
            if partial && index == records.count / 2 { throw networkError() }
        }
    }
    func fetchPendingChanges() async throws -> [SyncRecordEnvelope] {
        if fault == .fetch { fault = .none; throw networkError() }
        await refresh()
        defer { inbound = [] }
        return inbound
    }
}

private struct SyncDevice {
    let directory: URL
    var repository: SQLiteLibraryRepository
    let metadata: SyncMetadataStore
    var service: OfflineFirstSyncService
    var transport: FaultTransport

    static func make(at directory: URL, cloud: TestCloud, seed: UInt64) async throws -> SyncDevice {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try SQLiteLibraryRepository(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        let metadata = SyncMetadataStore(directory: directory.appendingPathComponent("sync"))
        let transport = FaultTransport(cloud: cloud, seed: seed, metadata: metadata)
        let service = OfflineFirstSyncService(repository: repository,
            adapter: SQLiteLibrarySyncAdapter(repository: repository), transport: transport,
            metadataStore: metadata, backupURL: { directory.appendingPathComponent("backup.sqlite") })
        return SyncDevice(directory: directory, repository: repository, metadata: metadata,
            service: service, transport: transport)
    }
    mutating func restart(cloud: TestCloud, seed: UInt64) async throws {
        await service.stop()
        let reopened = try await Self.make(at: directory, cloud: cloud, seed: seed)
        repository = reopened.repository; service = reopened.service; transport = reopened.transport
    }
}

private func snapshot(_ repository: SQLiteLibraryRepository) async throws -> [String: Data] {
    let changes = try await repository.resourceRevisionSnapshot().enumerated().map { index, r in
        LibraryChange(cursor: Int64(index + 1), transactionID: UUID(), sequence: index,
            eventType: "snapshot", resourceType: r.resourceType, resourceID: r.resourceID,
            revision: r.revision, isTombstone: r.isDeleted, occurredAt: r.updatedAt)
    }
    let records = try await SQLiteLibrarySyncAdapter(repository: repository).encode(changes: changes, deviceID: "snapshot")
    // Library identities and aliases are intentionally local; compare content.
    return Dictionary(records.filter { !$0.isTombstone && $0.resourceKind != "library"
        && $0.resourceKind != "portableTypeMapping" }.map { (resourceKey($0), $0.payload) },
        uniquingKeysWith: { _, last in last })
}

private func textItem(id: UUID, type: ItemType, text: String, deckID: UUID?) -> Item {
    Item(id: id, itemTypeID: type.id, fields: type.fields.map {
        FieldValue(fieldID: $0.id, value: $0.type == .richText ? .rich([Span(text)]) : .text(text))
    }, deckID: deckID)
}

struct SyncStateMachineTests {
    @Test func independentEquivalentItemTypesMustConvergeAcrossCloudAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = TestCloud()
        let first = try await SyncDevice.make(at: root.appendingPathComponent("first"), cloud: cloud, seed: 33)
        var second = try await SyncDevice.make(at: root.appendingPathComponent("second"), cloud: cloud, seed: 34)
        let base = try #require(try await first.repository.loadItemTypes().itemTypes.first)
        let a = ItemType(name: "Equivalent schema", fields: base.fields, templates: base.templates)
        let b = ItemType(name: "Equivalent schema", fields: base.fields, templates: base.templates)
        _ = try await first.repository.createItemType(a)
        _ = try await second.repository.createItemType(b)
        let firstItem = textItem(id: UUID(), type: a, text: "First", deckID: nil)
        let secondItem = textItem(id: UUID(), type: b, text: "Second", deckID: nil)
        _ = try await first.repository.createItem(firstItem, asOf: .now)
        _ = try await second.repository.createItem(secondItem, asOf: .now)
        for _ in 0..<6 { await first.service.synchronize(); await second.service.synchronize() }
        #expect(try await snapshot(first.repository) == snapshot(second.repository))
        try await second.restart(cloud: cloud, seed: 35)
        let edited = textItem(id: secondItem.id, type: b, text: "Edited after restart", deckID: nil)
        _ = try await second.repository.updateItem(edited, asOf: .now)
        for _ in 0..<4 { await second.service.synchronize(); await first.service.synchronize() }
        #expect(try await first.repository.item(id: edited.id)?.item.fields == edited.fields)
        #expect(await first.service.issues().isEmpty)
        #expect(await second.service.issues().isEmpty)
    }

    @Test func partialUploadSurvivesRestartWithoutLosingOrDuplicatingResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = TestCloud()
        var device = try await SyncDevice.make(at: root, cloud: cloud, seed: 55)
        await device.service.synchronize()
        for index in 0..<9 { _ = try await device.repository.createDeck(Deck(name: "pending\(index)")) }
        await device.transport.inject(.afterPartialSend)
        await device.service.synchronize()
        let interrupted = try await device.metadata.load()
        #expect(interrupted.pendingOutbound?.count == 9)
        #expect(interrupted.outboundCursor == (try await device.repository.currentChangeCursor()))
        #expect(await device.service.status() == .offline)
        try await device.restart(cloud: cloud, seed: 56)
        await device.service.synchronize()
        #expect(try await device.metadata.load().pendingOutbound?.isEmpty == true)
        let server = await cloud.snapshot().values.filter { $0.record.resourceKind == "deck" && !$0.record.isTombstone }
        #expect(server.count == 9)
        #expect(try await device.repository.deckSummaries(asOf: .now).count == 9)
    }

    @Test(arguments: [false, true])
    func offlineConflictSurvivesRestartAndPreservesLosingVersion(delete: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = TestCloud()
        let first = try await SyncDevice.make(at: root.appendingPathComponent("first"), cloud: cloud, seed: 66)
        var second = try await SyncDevice.make(at: root.appendingPathComponent("second"), cloud: cloud, seed: 67)
        let deck = try await first.repository.createDeck(Deck(name: "Baseline"))
        await first.service.synchronize(); await second.service.synchronize()
        _ = try await second.repository.updateDeck(Deck(id: deck.id, name: "Offline edit to recover"))
        if delete {
            try await first.repository.commitDeckDeletion(id: deck.id, policy: .unassignItems, asOf: .now)
        } else {
            _ = try await first.repository.updateDeck(Deck(id: deck.id, name: "Server winner"))
        }
        await first.service.synchronize()
        try await second.restart(cloud: cloud, seed: 68)
        await second.service.synchronize()
        let issues = await second.service.issues()
        let issue = try #require(issues.first { $0.resourceID == deck.id.uuidString && $0.conflictCopy != nil })
        #expect(issue.kind == (delete ? .deleteVersusEdit : .deckConflict))
        #expect(issue.conflictCopy?.isRestorable == true)
        for _ in 0..<3 { await second.service.synchronize() }
        #expect(await second.service.issues().count == 1)
        try await second.restart(cloud: cloud, seed: 69)
        await second.service.synchronize()
        try await second.service.restoreConflictCopy(forIssueID: issue.id)
        let recovered = try await second.repository.deckSummaries(asOf: .now)
        #expect(recovered.contains { $0.name == "Offline edit to recover (Recovered)" })
        #expect(await second.service.issues().isEmpty)
    }

    @Test func randomMalformedEnvelopesRollBackTheWholeBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await SyncDevice.make(at: root.appendingPathComponent("source"), cloud: TestCloud(), seed: 77)
        let target = try await SyncDevice.make(at: root.appendingPathComponent("target"), cloud: TestCloud(), seed: 78)
        let deck = try await source.repository.createDeck(Deck(name: "Must roll back"))
        let sourceAdapter = SQLiteLibrarySyncAdapter(repository: source.repository)
        let good = try #require(try await sourceAdapter.encode(changes: source.repository.changes(after: 0, limit: 100), deviceID: "source")
            .first { $0.id == deck.id.uuidString })
        let adapter = SQLiteLibrarySyncAdapter(repository: target.repository)
        let before = try await snapshot(target.repository)
        let cursor = try await target.repository.currentChangeCursor()
        var random = SyncRandom(state: 0xf00d)
        for iteration in 0..<150 {
            let mutation = iteration % 5
            let bad = SyncRecordEnvelope(
                id: mutation == 0 ? random.uuid().uuidString : mutation == 4 ? "invalid-uuid" : good.id,
                resourceKind: mutation == 1 ? "review" : mutation == 2 ? "unsupported" : good.resourceKind,
                revision: good.revision, deviceID: good.deviceID, order: good.order,
                isTombstone: mutation == 4,
                payload: mutation == 3 ? good.payload.prefix(random.index(good.payload.count)) : good.payload
            )
            await #expect(throws: (any Error).self) { try await adapter.applyRemote([good, bad], origin: .cloud) }
            #expect(try await snapshot(target.repository) == before, "mutation=\(iteration) partially applied")
            #expect(try await target.repository.currentChangeCursor() == cursor)
        }
    }

    @Test(arguments: ["bytes", "kind", "extension", "signature"])
    func corruptAssetCannotCommitAnAccompanyingDomainChange(mutation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await SyncDevice.make(at: root.appendingPathComponent("source"), cloud: TestCloud(), seed: 88)
        let target = try await SyncDevice.make(at: root.appendingPathComponent("target"), cloud: TestCloud(), seed: 89)
        _ = try await source.repository.createDeck(Deck(name: "Must not commit"))
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        _ = try await source.repository.reserveMedia(data: png, kind: .image, altText: nil, reservationID: UUID(), asOf: .now)
        var records = try await SQLiteLibrarySyncAdapter(repository: source.repository).encode(
            changes: source.repository.changes(after: 0, limit: 100), deviceID: "source")
        let asset = try #require(records.first { $0.resourceKind == "media" })
        let url = try #require(asset.stagedFileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        if mutation == "bytes" {
            try Data("corrupt bytes".utf8).write(to: url)
        } else {
            let descriptor = try #require(asset.asset)
            let bad = SyncRecordEnvelope(id: asset.id, resourceKind: asset.resourceKind,
                revision: asset.revision, deviceID: asset.deviceID, order: asset.order,
                isTombstone: false, payload: asset.payload,
                asset: SyncAssetDescriptor(hash: descriptor.hash, byteSize: descriptor.byteSize,
                    signature: mutation == "signature" ? String(repeating: "0", count: 64) : descriptor.signature,
                    fileExtension: mutation == "extension" ? "../outside" : descriptor.fileExtension,
                    contentType: mutation == "kind" ? "audio" : descriptor.contentType), stagedFileURL: url)
            records = records.map { $0.id == asset.id ? bad : $0 }
        }
        let before = try await snapshot(target.repository)
        await #expect(throws: SQLiteLibrarySyncError.self) {
            try await SQLiteLibrarySyncAdapter(repository: target.repository).applyRemote(records, origin: .cloud)
        }
        #expect(try await snapshot(target.repository) == before)
    }

    @Test func firstMergeMustUnionLibrariesBeforePublishingCollidingIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = TestCloud()
        let first = try await SyncDevice.make(at: root.appendingPathComponent("first"), cloud: cloud, seed: 8)
        let second = try await SyncDevice.make(at: root.appendingPathComponent("second"), cloud: cloud, seed: 9)
        let id = UUID()
        _ = try await first.repository.createDeck(Deck(id: id, name: "Server original"))
        await first.service.synchronize()
        _ = try await second.repository.createDeck(Deck(id: id, name: "Independent local original"))
        await second.service.synchronize()
        let decks = try await second.repository.deckSummaries(asOf: .now)
        #expect(Set(decks.map(\.name)) == ["Server original", "Independent local original"])
    }

    @Test func emptyCloudCompletesFirstMergeAndCreatesVerifiedBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try await SyncDevice.make(at: root, cloud: TestCloud(), seed: 1)
        await device.service.synchronize()
        #expect(try await device.metadata.load().didCompleteInitialMerge == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup.sqlite").path))
    }

    @Test func remoteEchoMustNotHideAnInterveningLocalEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try await SyncDevice.make(at: root, cloud: TestCloud(), seed: 2)
        let deck = try await device.repository.createDeck(Deck(name: "Imported"))
        let adapter = SQLiteLibrarySyncAdapter(repository: device.repository)
        let remote = try await adapter.encode(changes: device.repository.changes(after: 0, limit: 100), deviceID: "remote")
        try await adapter.applyRemote(remote, origin: .cloud)
        let cursor = try await device.repository.currentChangeCursor()
        _ = try await device.repository.updateDeck(Deck(id: deck.id, name: "Edited locally"))
        let outgoing = try await adapter.encode(changes: device.repository.changes(after: cursor, limit: 100), deviceID: "local")
        #expect(outgoing.contains { $0.resourceKind == "deck" && $0.id == deck.id.uuidString })
    }

    @Test(arguments: syncFuzzSeeds())
    func randomizedThreeDeviceConvergence(seed: UInt64) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-seed-\(seed)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = TestCloud()
        var random = SyncRandom(state: seed)
        var devices: [SyncDevice] = []
        for index in 0..<3 {
            devices.append(try await .make(at: root.appendingPathComponent("device-\(index)"), cloud: cloud, seed: random.next()))
        }
        let type = try #require(try await devices[0].repository.loadItemTypes().itemTypes.first)
        var activeItems: [UUID: Item] = [:]
        var expectedReviews: Set<UUID> = []
        var decks: [UUID] = []
        var trace: [String] = []
        let steps = min(1_000, max(1, Int(ProcessInfo.processInfo.environment["NEOANKI_SYNC_FUZZ_STEPS"] ?? "45") ?? 45))
        for step in 0..<steps {
            let who = random.index(3)
            let repository = devices[who].repository
            let operation = random.index(8)
            let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(step * 86_400))
            let ids = activeItems.keys.sorted { $0.uuidString < $1.uuidString }
            let selected = ids.isEmpty ? nil : ids[random.index(ids.count)]
            trace.append("\(step):device\(who):op\(operation)")
            switch operation {
            case 0:
                let id = random.uuid()
                let item = textItem(id: id, type: type, text: "seed\(seed)-create\(step)", deckID: decks.last)
                _ = try await repository.createItem(item, asOf: date)
                activeItems[id] = item
            case 1:
                if let id = selected, let old = activeItems[id] {
                    let item = textItem(id: id, type: type, text: "seed\(seed)-edit\(step)", deckID: old.deckID)
                    _ = try await repository.updateItem(item, asOf: date)
                    activeItems[id] = item
                }
            case 2:
                if let id = selected {
                    let card = try #require(try await repository.cards().first { $0.itemID == id })
                    let review = try await repository.submitReview(cardID: card.id, rating: .good, asOf: date, durationMilliseconds: step + 1)
                    expectedReviews.insert(review.reviewLogID)
                }
            case 3:
                let deck = Deck(id: random.uuid(), name: "seed\(seed)-deck\(step)", parentID: decks.last)
                _ = try await repository.createDeck(deck); decks.append(deck.id)
            case 4:
                if let id = decks.last {
                    let old = try await repository.deck(id: id)
                    _ = try await repository.updateDeck(Deck(id: id, name: "renamed\(step)", parentID: old.parentID))
                }
            case 5: try await repository.setStudyDayRolloverMinutes(random.index(1_440))
            case 6: try await devices[who].restart(cloud: cloud, seed: random.next())
            default:
                // Delete only unreviewed items; immutable review retention has
                // separate tests and must never be confused with a lost review.
                if let id = selected, expectedReviews.isEmpty {
                    _ = try await repository.deleteItem(id: id, asOf: date); activeItems[id] = nil
                }
            }
            let fault: FaultTransport.Fault = [.none, .start, .fetch, .beforeSend, .afterPartialSend][random.index(5)]
            await devices[who].transport.inject(fault)
            await devices[who].service.synchronize()
            if random.index(4) == 0 { try await devices[who].restart(cloud: cloud, seed: random.next()) }
            // Bounded quiescence: a broken protocol fails with the complete
            // trace instead of running until a physical device appears healthy.
            for _ in 0..<6 {
                for index in (0..<3).shuffled(using: &random) { await devices[index].service.synchronize() }
            }
            let canonical = try await snapshot(devices[who].repository)
            for device in devices {
                let actual = try await snapshot(device.repository)
                let differing = Set(actual.keys).union(canonical.keys).filter { actual[$0] != canonical[$0] }.sorted()
                let detail = differing.prefix(2).map { "\($0) actual=\(String(decoding: actual[$0] ?? Data(), as: UTF8.self)) expected=\(String(decoding: canonical[$0] ?? Data(), as: UTF8.self))" }
                try #require(differing.isEmpty, "seed=\(seed) trace=\(trace.joined(separator: ",")) differences=\(detail)")
                for (id, expected) in activeItems {
                    #expect(try await device.repository.item(id: id)?.item == expected, "seed=\(seed) step=\(step) item=\(id)")
                }
                for id in expectedReviews {
                    #expect(try await device.repository.reviewLog(id: id).id == id, "seed=\(seed) step=\(step) lost review")
                }
                #expect(actual.keys.filter { $0.hasPrefix("review:") }.count == expectedReviews.count,
                    "seed=\(seed) step=\(step): fabricated duplicate review IDs")
                #expect(actual.keys.filter { $0.hasPrefix("item:") }.count == activeItems.count,
                    "seed=\(seed) step=\(step): lost or duplicated items")
                #expect(try await device.metadata.load().stagedInbound.isEmpty, "seed=\(seed) step=\(step) undelivered batch")
                let issues = await device.service.issues()
                try #require(issues.isEmpty, "seed=\(seed) step=\(step) unexpected issues=\(issues.map { "\($0.kind):\($0.summary):\($0.conflictCopy?.resourceKind ?? "none")" })")
            }
        }
        let cursors = try await devices.asyncMap { try await $0.repository.currentChangeCursor() }
        for device in devices { await device.service.synchronize() }
        let after = try await devices.asyncMap { try await $0.repository.currentChangeCursor() }
        #expect(after == cursors, "seed=\(seed): echo loop after quiescence")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for value in self { result.append(try await transform(value)) }
        return result
    }
}

private func syncFuzzSeeds() -> [UInt64] {
    let env = ProcessInfo.processInfo.environment
    if let seed = env["NEOANKI_SYNC_FUZZ_SEED"].flatMap(UInt64.init) { return [seed] }
    let count = min(128, max(1, Int(env["NEOANKI_SYNC_FUZZ_SEEDS"] ?? "8") ?? 8))
    var seeds: [UInt64] = [1, 7, 42, 99, 0xdeadbeef, 0xc0ffee, 20261002, UInt64.max]
    var candidate: UInt64 = 0
    while seeds.count < count {
        if !seeds.contains(candidate) { seeds.append(candidate) }
        candidate += 1
    }
    return Array(seeds.prefix(count))
}
