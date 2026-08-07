import Foundation
import NeoAnkiApplication
import NeoAnkiCloudSync
import Testing

struct SyncMergePolicyTests {
    @Test func immutableReviewsAreUnionMerged() {
        let local = envelope(id: "review-a", kind: "review", device: "a", order: 1)
        let remote = envelope(id: "review-b", kind: "review", device: "b", order: 1)
        let result = SyncMergePolicy.merge(local: [local], server: [remote])
        #expect(result.accepted.count == 2)
        #expect(result.conflictCopies.isEmpty)
    }

    @Test func mutableServerValueWinsWhileLocalCopyIsPreserved() {
        let local = envelope(id: "item-a", kind: "item", device: "a", order: 1, payload: Data("local".utf8))
        let remote = envelope(id: "item-a", kind: "item", device: "b", order: 1, payload: Data("remote".utf8))
        let result = SyncMergePolicy.merge(local: [local], server: [remote])
        #expect(result.accepted == [remote])
        #expect(result.conflictCopies.count == 1)
        #expect(result.conflictCopies.first?.payload == local.payload)
    }

    private func envelope(
        id: String,
        kind: String,
        device: String,
        order: Int64,
        payload: Data = Data()
    ) -> SyncRecordEnvelope {
        SyncRecordEnvelope(
            id: id,
            resourceKind: kind,
            revision: 1,
            deviceID: device,
            order: order,
            isTombstone: false,
            payload: payload
        )
    }
}
