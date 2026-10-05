@testable import NeoAnkiCloudSync
import CloudKit
import Foundation
import NeoAnkiApplication
import Testing

struct CKSyncEngineTransportTests {
    @Test func malformedCloudRecordsArePreservedInsteadOfSilentlyDiscarded() {
        let malformed = CKRecord(recordType: "LibraryResource", recordID: .init(recordName: "deck__malformed"))
        malformed["resourceKind"] = "deck" as CKRecordValue
        let received = CKSyncEngineTransport.receivedEnvelope(from: malformed)
        #expect(received.id == malformed.recordID.recordName)
        #expect(received.resourceKind == "invalidCloudKitRecord")
        #expect(!received.payload.isEmpty)
        let good = SyncRecordEnvelope(id: "test", resourceKind: "deck", revision: 1,
            deviceID: "test", order: 1, isTombstone: false, payload: Data("payload".utf8))
        #expect(CKSyncEngineTransport.receivedEnvelope(from: CKSyncEngineTransport.record(
            from: good, id: .init(recordName: "deck__test"))) == good)
    }

    @Test func coldLookupMustNotRecreateAServerDeletionOrOverwriteAConcurrentEdit() {
        func value(_ text: String) -> SyncRecordEnvelope {
            SyncRecordEnvelope(id: "test", resourceKind: "deck", revision: 1,
                deviceID: "test", order: 1, isTombstone: false, payload: Data(text.utf8))
        }
        let baseline = value("baseline"), local = value("offline edit"), server = value("server edit")
        let deletion = CKSyncEngineTransport.conflictingVersion(local: local, baseline: baseline, server: nil, knownAbsent: true)
        #expect(deletion?.isTombstone == true)
        #expect(CKSyncEngineTransport.conflictingVersion(local: local, baseline: baseline, server: server, knownAbsent: false) == server)
        #expect(CKSyncEngineTransport.conflictingVersion(local: local, baseline: baseline, server: nil, knownAbsent: false) == nil)
        #expect(CKSyncEngineTransport.conflictingVersion(local: local, baseline: baseline, server: local, knownAbsent: false) == nil)
        #expect(CKSyncEngineTransport.conflictingVersion(local: local, baseline: baseline, server: baseline, knownAbsent: false) == nil)
    }

    @Test func anOlderAcknowledgementCannotDiscardANewerQueuedEdit() async {
        let buffers = TransportBuffers()
        let id = CKRecord.ID(recordName: "deck__test")
        let old = SyncRecordEnvelope(id: "test", resourceKind: "deck", revision: 1,
            deviceID: "device", order: 1, isTombstone: false, payload: Data("old".utf8))
        let new = SyncRecordEnvelope(id: "test", resourceKind: "deck", revision: 2,
            deviceID: "device", order: 2, isTombstone: false, payload: Data("new".utf8))
        await buffers.enqueue(new, id: id)
        await buffers.acknowledge([CKSyncEngineTransport.record(from: old, id: id)], deleted: [])
        #expect(await buffers.envelope(for: id) == new)
        #expect(await buffers.hasPending([id]))
        await buffers.acknowledge([CKSyncEngineTransport.record(from: new, id: id)], deleted: [])
        #expect(!(await buffers.hasPending([id])))
    }

    @Test func deleteAcknowledgementCannotDiscardANewerRecreation() async {
        let buffers = TransportBuffers()
        let id = CKRecord.ID(recordName: "deck__test")
        let new = SyncRecordEnvelope(id: "test", resourceKind: "deck", revision: 2,
            deviceID: "device", order: 2, isTombstone: false, payload: Data("recreated".utf8))
        await buffers.enqueue(new, id: id)
        await buffers.acknowledge([], deleted: [id])
        #expect(await buffers.envelope(for: id) == new)
    }

    @Test func completeInitialFetchIdentifiesAbsentRecordsWithoutExtraLookups() async {
        let buffers = TransportBuffers()
        let id = CKRecord.ID(recordName: "item__new")
        #expect(!(await buffers.isAbsent(id)))
        await buffers.completedInitialFetch()
        #expect(await buffers.isAbsent(id))
        await buffers.remember([CKRecord(recordType: "LibraryResource", recordID: id)])
        #expect(!(await buffers.isAbsent(id)))
        await buffers.forget([id])
        #expect(await buffers.isAbsent(id))
    }

    @Test func unchangedContentDoesNotRequireUploadButEditsAndDeletesDo() {
        let value = SyncRecordEnvelope(id: "test", resourceKind: "item", revision: 1,
            deviceID: "Mac", order: 1, isTombstone: false, payload: Data("content".utf8))
        let server = CKSyncEngineTransport.record(from: value, id: .init(recordName: "item__test"))
        let imported = SyncRecordEnvelope(id: "test", resourceKind: "item", revision: 20,
            deviceID: "phone", order: 900, isTombstone: false, payload: value.payload)
        #expect(CKSyncEngineTransport.matchesServer(imported, record: server))
        let edit = SyncRecordEnvelope(id: "test", resourceKind: "item", revision: 21,
            deviceID: "phone", order: 901, isTombstone: false, payload: Data("edited".utf8))
        #expect(!CKSyncEngineTransport.matchesServer(edit, record: server))
        let deletion = SyncRecordEnvelope(id: "test", resourceKind: "item", revision: 21,
            deviceID: "phone", order: 901, isTombstone: true, payload: Data())
        #expect(!CKSyncEngineTransport.matchesServer(deletion, record: server))
    }

    @Test func updatesFetchedRecordInsteadOfRecreatingItAndClearsOldAsset() {
        let id = CKRecord.ID(recordName: "item__test")
        let existing = CKRecord(recordType: "LibraryResource", recordID: id)
        existing["assetHash"] = "old-hash" as CKRecordValue
        let envelope = SyncRecordEnvelope(
            id: "test", resourceKind: "item", revision: 2, deviceID: "phone",
            order: 8, isTombstone: false, payload: Data("edited".utf8)
        )
        let updated = CKSyncEngineTransport.record(from: envelope, id: id, serverRecord: existing)
        #expect(updated === existing)
        #expect(updated["payload"] as? Data == envelope.payload)
        #expect(updated["assetHash"] == nil)
    }

    @Test func suppressesOnlyConflictsWithRecoverableServerRecords() {
        let server = CKRecord(recordType: "LibraryResource", recordID: .init(recordName: "item__test"))
        let conflict = NSError(domain: CKErrorDomain, code: CKError.Code.serverRecordChanged.rawValue,
            userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: ["test": conflict]])
        #expect(CKSyncEngineTransport.containsOnlyServerConflicts(partial))
        #expect(!CKSyncEngineTransport.containsOnlyServerConflicts(
            NSError(domain: CKErrorDomain, code: CKError.Code.networkFailure.rawValue)))
    }

    @Test func acceptsTheConfiguredContainerEntitlement() throws {
        try CKSyncEngineTransport.validateContainerIdentifiers([
            "iCloud.example.unrelated",
            CKSyncEngineTransport.containerIdentifier,
        ])
    }

    @Test func rejectsMissingContainerEntitlementsBeforeCreatingCloudKitObjects() {
        #expect(throws: CKSyncEngineTransportError.missingContainerEntitlement(
            CKSyncEngineTransport.containerIdentifier
        )) {
            try CKSyncEngineTransport.validateContainerIdentifiers(nil)
        }
        #expect(throws: CKSyncEngineTransportError.missingContainerEntitlement(
            CKSyncEngineTransport.containerIdentifier
        )) {
            try CKSyncEngineTransport.validateContainerIdentifiers(["iCloud.example.unrelated"])
        }
    }
}
