@testable import NeoAnkiCloudSync
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

struct LibraryZoneChangeFetcherTests {
    private func record(_ id: String) -> SyncRecordEnvelope {
        .init(id: id, resourceKind: "card", revision: 1, deviceID: "phone", order: 1,
              isTombstone: false, payload: Data(id.utf8))
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
}
