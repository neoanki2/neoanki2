@testable import NeoAnkiCloudSync
import Foundation
import NeoAnkiApplication
import Testing

struct SyncMetadataStoreTests {
    @Test func exactUploadReceiptKeepsAnEditQueuedDuringTheSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = SyncRecordEnvelope(id: "deck", resourceKind: "deck", revision: 1, deviceID: "mac",
            order: 1, isTombstone: false, payload: Data([1]))
        let later = SyncRecordEnvelope(id: "deck", resourceKind: "deck", revision: 2, deviceID: "mac",
            order: 2, isTombstone: false, payload: Data([2]))
        let store = SyncMetadataStore(directory: root)
        try await store.appendOutgoing([existing], cursor: 1)
        try await store.beginUpload([existing])
        await store.beginZoneRead()
        try await store.appendOutgoing([later], cursor: 2)
        try await store.finishOutgoing([existing])
        await store.endUpload([existing])
        try await store.receiveZonePage([existing], token: Data([1]))
        await store.endZoneRead()

        let resumed = try await SyncMetadataStore(directory: root).load()
        #expect(resumed.pendingOutbound == [later])
        #expect(resumed.inboundNeedingConfirmation == [existing.syncKey])
        #expect(resumed.libraryZoneChangeToken == Data([1]))
    }
    @Test func onlySupportedMutableContentAdvertisesConflictRestoration() {
        for kind in ["card", "review", "reviewRevert", "media", "schedulingSettings", "library"] {
            let copy = SyncConflictCopy(resourceKind: kind, originalResourceID: "id", sourceDeviceID: "test",
                payload: Data("preserved content".utf8))
            #expect(!copy.isRestorable)
        }
        for kind in ["deck", "item", "itemType"] {
            let copy = SyncConflictCopy(resourceKind: kind, originalResourceID: "id", sourceDeviceID: "test",
                payload: Data("preserved content".utf8))
            #expect(copy.isRestorable)
        }
    }

    private func envelope(id: String = "deck", payload: String = "original", file: URL? = nil,
                          asset: SyncAssetDescriptor? = nil) -> SyncRecordEnvelope {
        SyncRecordEnvelope(id: id, resourceKind: "deck", revision: 1, deviceID: "test", order: 1,
            isTombstone: false, payload: Data(payload.utf8), asset: asset, stagedFileURL: file)
    }

    @Test func deliveredInboxSurvivesRestartAndStaleBookkeeping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        try await store.save(SyncMetadata(outboundCursor: 20))
        let stale = try await store.load()
        let received = envelope()
        try await store.receive([received])
        try await store.save(stale)
        let restarted = SyncMetadataStore(directory: root)
        #expect(try await restarted.load().stagedInbound == [received])
        #expect(try await restarted.load().outboundCursor == 20)
    }

    @Test func commitCannotEraseANewerDeliveryForTheSameResource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        let old = envelope(), new = envelope(payload: "new delivery")
        try await store.receive([old])
        let serviceSnapshot = try await store.load()
        try await store.receive([new])
        let committed = try await store.completeIncoming([old], metadata: serviceSnapshot)
        #expect(committed.stagedInbound == [new])
        #expect(try await store.load().stagedInbound == [new])
    }

    @Test func acknowledgedBaselineCannotBeOverwrittenByAnOldSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        try await store.save(SyncMetadata())
        let stale = try await store.load()
        let ack = envelope()
        try await store.acknowledge([ack])
        try await store.save(stale)
        #expect(try await store.load().serverBaseline?["deck:deck"] == ack)
    }

    @Test func conflictCopiesAreDeduplicatedAcrossRestarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = envelope(), server = envelope(payload: "server winner")
        for _ in 0..<5 {
            let store = SyncMetadataStore(directory: root)
            try await store.preserveConflict(local: local, server: server)
        }
        let issues = try await SyncMetadataStore(directory: root).load().issues
        #expect(issues.count == 1)
        #expect(issues.first?.conflictCopy?.payload == local.payload)
        let store = SyncMetadataStore(directory: root)
        let stale = try await store.load()
        _ = try await store.completeConflicts([#require(issues.first)])
        #expect(try await store.load().resolvedConflictCopies?.first?.payload == local.payload)
        try await store.preserveConflict(local: local, server: server)
        #expect(try await store.load().issues.isEmpty)
        // Outbound bookkeeping from an earlier snapshot cannot erase history.
        var oldBookkeeping = stale
        oldBookkeeping.issues = []
        try await store.save(oldBookkeeping)
        #expect(try await store.load().resolvedConflictCopies?.count == 1)
    }

    @Test func completingOneConflictDoesNotLoseAnotherTransportConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        try await store.preserveConflict(local: envelope(id: "first"), server: envelope(id: "first", payload: "server"))
        let first = try #require(try await store.load().issues.first)
        try await store.preserveConflict(local: envelope(id: "second"), server: envelope(id: "second", payload: "server"))
        let completed = try await store.completeConflicts([first])
        #expect(completed.issues.count == 1)
        #expect(completed.issues.first?.resourceID == "second")
        #expect(completed.resolvedConflictCopies?.count == 1)
        #expect(completed.resolvedConflictCopies?.first?.originalResourceID == "first")
    }

    @Test func conflictBatchStagesServerChangesAndPreservesLosingCopiesAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        let review = SyncRecordEnvelope(id: "review", resourceKind: "review", revision: 1,
            deviceID: "mac", order: 1, isTombstone: false, payload: Data("review".utf8))
        let token = Data([1])
        try await store.receiveZonePage([review], token: token)
        let conflicts: [SyncMetadataStore.Conflict] = (1...213).map { index in
            let id = "record-\(index)"
            return (local: envelope(id: id), server: envelope(id: id, payload: "from server"))
        }
        try await store.receiveConflicts(conflicts + conflicts)

        let restarted = SyncMetadataStore(directory: root)
        let recovered = try await restarted.load()
        #expect(recovered.libraryZoneChangeToken == token)
        #expect(Set(recovered.stagedInbound.map(\.id)) == Set(conflicts.map { $0.server.id } + [review.id]))
        #expect(recovered.issues.count == conflicts.count)
        #expect(recovered.issues.allSatisfy { $0.conflictCopy?.payload == Data("original".utf8) })

        let completed = try await restarted.completeConflicts(recovered.issues)
        #expect(completed.resolvedConflictCopies?.count == conflicts.count)
        #expect(completed.issues.isEmpty)
        try await restarted.receiveConflicts(conflicts)
        #expect(try await restarted.load().issues.isEmpty)
    }

    @Test func conflictBatchDoesNotCommitCopiesIfServerAssetStagingFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncMetadataStore(directory: root)
        let delivered = envelope(id: "unrelated")
        try await store.receive([delivered])
        let asset = SyncAssetDescriptor(hash: "hash", byteSize: 5, signature: "hash",
            fileExtension: "png", contentType: "image")
        let broken = envelope(id: "second", payload: "from server",
            file: root.appendingPathComponent("missing.png"), asset: asset)
        await #expect(throws: (any Error).self) {
            try await store.receiveConflicts([
                (local: envelope(id: "first"), server: envelope(id: "first", payload: "from server")),
                (local: envelope(id: "second"), server: broken)
            ])
        }
        let recovered = try await store.load()
        #expect(recovered.issues.isEmpty)
        #expect(recovered.stagedInbound == [delivered])
    }

    @Test func legacyMetadataWithoutNewFieldsStillDecodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        var dictionary = try #require(PropertyListSerialization.propertyList(
            from: encoder.encode(SyncMetadata(outboundCursor: 321, didCompleteInitialMerge: true)),
            format: nil) as? [String: Any])
        dictionary.removeValue(forKey: "pendingOutbound")
        dictionary.removeValue(forKey: "serverBaseline")
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            .write(to: root.appendingPathComponent("cloud-sync-metadata.plist"))
        let recovered = try await SyncMetadataStore(directory: root).load()
        #expect(recovered.outboundCursor == 321)
        #expect(recovered.pendingOutbound == nil)
        #expect(recovered.serverBaseline == nil)
        #expect(recovered.didCompleteInitialMerge == true)
    }

    @Test func stagingDoesNotTrustRemotePathsOrDeleteExternalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png")
        try Data("asset bytes".utf8).write(to: source)
        let descriptor = SyncAssetDescriptor(hash: "../../escape", byteSize: 11, signature: "invalid",
            fileExtension: "../../escape", contentType: "image")
        let store = SyncMetadataStore(directory: root.appendingPathComponent("sync"))
        let staged = try await store.stageAssets(in: [envelope(file: source, asset: descriptor)])
        let url = try #require(staged.first?.stagedFileURL)
        #expect(url.deletingLastPathComponent().lastPathComponent == "inbound-assets")
        await store.removeStagedAssets(in: [envelope(file: source, asset: descriptor)])
        #expect(FileManager.default.fileExists(atPath: source.path))
        await store.removeStagedAssets(in: staged)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func partialAssetStagingFailureCleansOnlyNewFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("present.png")
        try Data("asset".utf8).write(to: source)
        let descriptor = SyncAssetDescriptor(hash: "hash", byteSize: 5, signature: "hash", fileExtension: "png", contentType: "image")
        let store = SyncMetadataStore(directory: root.appendingPathComponent("sync"))
        await #expect(throws: (any Error).self) {
            _ = try await store.stageAssets(in: [
                envelope(file: source, asset: descriptor),
                envelope(id: "missing", file: root.appendingPathComponent("missing.png"), asset: descriptor),
            ])
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sync/inbound-assets").path)
        #expect(remaining.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func repeatedDeliveryReusesTheDurableStagedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("transient.png")
        let bytes = Data("asset".utf8)
        try bytes.write(to: source)
        let descriptor = SyncAssetDescriptor(hash: "hash", byteSize: 5, signature: "hash",
            fileExtension: "png", contentType: "image")
        let store = SyncMetadataStore(directory: root.appendingPathComponent("sync"))
        let record = envelope(file: source, asset: descriptor)
        try await store.receive([record])
        let staged = try #require(try await store.load().stagedInbound.first?.stagedFileURL)
        try FileManager.default.removeItem(at: source)

        let token = Data([1])
        try await store.receiveZonePage([record], token: token)
        let replayed = try await store.load()
        #expect(replayed.libraryZoneChangeToken == token)
        #expect(replayed.stagedInbound.first?.stagedFileURL == staged)
        #expect(try Data(contentsOf: staged) == bytes)
    }

    @Test func outboundAssetsSurviveDeletionOfTheTransientSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("transient.png")
        let bytes = Data("queued asset".utf8)
        try bytes.write(to: source)
        let descriptor = SyncAssetDescriptor(hash: "hash", byteSize: 12, signature: "hash", fileExtension: "png", contentType: "image")
        let store = SyncMetadataStore(directory: root.appendingPathComponent("sync"))
        let staged = try await store.stageOutbound([envelope(file: source, asset: descriptor)])
        try await store.save(SyncMetadata(pendingOutbound: staged))
        try FileManager.default.removeItem(at: source)
        let restarted = SyncMetadataStore(directory: root.appendingPathComponent("sync"))
        let pending = try #require(try await restarted.load().pendingOutbound)
        let saved = try #require(pending.first?.stagedFileURL)
        #expect(try Data(contentsOf: saved) == bytes)
        await restarted.removeStagedAssets(in: pending)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }

    @Test(arguments: [false, true])
    func queuedAssetsSurviveContainerRelocation(legacyAbsoluteURLs: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldContainer = root.appendingPathComponent("old-container")
        let directory = oldContainer.appendingPathComponent("sync")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = oldContainer.appendingPathComponent("transient.png")
        let bytes = Data("queued image".utf8)
        try bytes.write(to: source)
        let descriptor = SyncAssetDescriptor(hash: "hash", byteSize: Int64(bytes.count), signature: "hash",
            fileExtension: "png", contentType: "image")
        let store = SyncMetadataStore(directory: directory)
        try await store.save(SyncMetadata(outboundCursor: 42, didCompleteInitialMerge: true))
        try await store.receive([envelope(id: "incoming", file: source, asset: descriptor)])
        var metadata = try await store.load()
        metadata.pendingOutbound = try await store.stageOutbound([envelope(id: "outgoing", file: source, asset: descriptor)])
        try await store.save(metadata)
        if legacyAbsoluteURLs {
            // Reproduce the on-device format from before this migration. The
            // update moves the data, but these absolute paths stay unchanged.
            try PropertyListEncoder().encode(metadata)
                .write(to: directory.appendingPathComponent("cloud-sync-metadata.plist"))
        } else {
            let stored = try PropertyListDecoder().decode(SyncMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent("cloud-sync-metadata.plist")))
            #expect(stored.stagedInbound.first?.stagedFileURL?.scheme == nil)
            #expect(stored.pendingOutbound?.first?.stagedFileURL?.scheme == nil)
        }
        try FileManager.default.removeItem(at: source)
        let newContainer = root.appendingPathComponent("new-container")
        try FileManager.default.moveItem(at: oldContainer, to: newContainer)
        let restarted = SyncMetadataStore(directory: newContainer.appendingPathComponent("sync"))
        let recovered = try await restarted.load()
        #expect(recovered.outboundCursor == 42)
        #expect(recovered.didCompleteInitialMerge == true)
        let inbox = try #require(recovered.stagedInbound.first)
        let outbox = try #require(recovered.pendingOutbound?.first)
        for record in [inbox, outbox] {
            let file = try #require(record.stagedFileURL)
            #expect(file.path.hasPrefix(newContainer.path + "/"))
            #expect(try Data(contentsOf: file) == bytes)
        }
        // A metadata write migrates legacy paths and remains usable on the
        // next update too, rather than repairing one installation only.
        try await restarted.save(recovered)
        let nextContainer = root.appendingPathComponent("next-container")
        try FileManager.default.moveItem(at: newContainer, to: nextContainer)
        let next = SyncMetadataStore(directory: nextContainer.appendingPathComponent("sync"))
        var pending = try await next.load()
        let incoming = try #require(pending.stagedInbound.first)
        let outgoing = try #require(pending.pendingOutbound?.first)
        #expect(try Data(contentsOf: #require(incoming.stagedFileURL)) == bytes)
        #expect(try Data(contentsOf: #require(outgoing.stagedFileURL)) == bytes)
        pending = try await next.completeIncoming([incoming], metadata: pending)
        #expect(pending.stagedInbound.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(incoming.stagedFileURL).path))
        #expect(try Data(contentsOf: #require(outgoing.stagedFileURL)) == bytes)
        pending.pendingOutbound = []
        try await next.save(pending)
        await next.removeStagedAssets(in: [outgoing])
        #expect(!FileManager.default.fileExists(atPath: try #require(outgoing.stagedFileURL).path))
    }

    @Test func corruptedMetadataDoesNotSilentlyResetTheCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("cloud-sync-metadata.plist")
        let invalid = Data("incomplete metadata".utf8)
        try invalid.write(to: file)
        await #expect(throws: (any Error).self) { _ = try await SyncMetadataStore(directory: root).load() }
        #expect(try Data(contentsOf: file) == invalid)
    }
}
