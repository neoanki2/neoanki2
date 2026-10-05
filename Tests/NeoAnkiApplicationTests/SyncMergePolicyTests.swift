import Foundation
import NeoAnkiApplication
import NeoAnkiCloudSync
import Testing

struct SyncMergePolicyTests {
    @Test func duplicateImmutableVersionsDoNotDependOnDeliveryOrder() {
        let older = envelope(id: "review", kind: "review", device: "same", order: 1, payload: Data("older".utf8))
        let newer = envelope(id: "review", kind: "review", device: "same", order: 2, payload: Data("newer".utf8))
        #expect(SyncMergePolicy.merge(local: [older, newer], server: []).accepted == [newer])
        #expect(SyncMergePolicy.merge(local: [newer, older], server: []).accepted == [newer])
        #expect(SyncMergePolicy.merge(local: [], server: [newer, older]).accepted == [newer])
    }

    @Test func equalClocksHaveAStableTieBreakIncludingTombstones() {
        let a = envelope(id: "deck", kind: "deck", device: "same", order: 1, payload: Data("a".utf8))
        let b = envelope(id: "deck", kind: "deck", device: "same", order: 1, payload: Data("b".utf8))
        let tombstone = SyncRecordEnvelope(id: a.id, resourceKind: a.resourceKind, revision: a.revision,
            deviceID: a.deviceID, order: a.order, isTombstone: true, payload: Data())
        #expect(SyncMergePolicy.merge(local: [a, b], server: []).accepted
            == SyncMergePolicy.merge(local: [b, a], server: []).accepted)
        #expect(SyncMergePolicy.merge(local: [a, tombstone], server: []).accepted == [tombstone])
        #expect(SyncMergePolicy.merge(local: [tombstone, a], server: []).accepted == [tombstone])
    }

    @Test func randomizedMergeIsIdempotentAndPermutationInvariant() {
        var random = MergeRandom(state: 0xabcde)
        for iteration in 0..<100 {
            let values = (0..<70).map { index in
                SyncRecordEnvelope(id: "resource\(index % 17)", resourceKind: index % 3 == 0 ? "review" : "deck",
                    revision: Int(random.next() % 5) + 1, deviceID: "device\(random.next() % 3)",
                    order: Int64(random.next() % 10), isTombstone: random.next() % 5 == 0,
                    payload: Data("payload\(random.next() % 7)".utf8))
            }
            let local = Array(values.prefix(35)), server = Array(values.suffix(35))
            let expected = SyncMergePolicy.merge(local: local, server: server).accepted
            for _ in 0..<5 {
                let actual = SyncMergePolicy.merge(local: local.shuffled(using: &random), server: server.shuffled(using: &random)).accepted
                #expect(actual == expected, "iteration=\(iteration)")
                #expect(Set(actual.map { "\($0.resourceKind):\($0.id)" }).count == actual.count)
            }
            #expect(SyncMergePolicy.merge(local: expected, server: []).accepted == expected)
        }
    }

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

private struct MergeRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}
