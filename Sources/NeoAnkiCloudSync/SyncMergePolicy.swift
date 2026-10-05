import Foundation
import NeoAnkiApplication

public struct SyncMergeResult: Sendable, Equatable {
    public let accepted: [SyncRecordEnvelope]
    public let conflictCopies: [SyncConflictCopy]

    public init(accepted: [SyncRecordEnvelope], conflictCopies: [SyncConflictCopy]) {
        self.accepted = accepted
        self.conflictCopies = conflictCopies
    }
}

/// Deterministic envelope-level policy. Review events and reverts are immutable
/// union members; mutable collisions accept the server value and preserve local.
public enum SyncMergePolicy {
    public static func merge(
        local: [SyncRecordEnvelope],
        server: [SyncRecordEnvelope],
        preservedAt: Date = .now
    ) -> SyncMergeResult {
        let immutableKinds = Set(["review", "reviewRevert"])
        var acceptedByKey: [String: SyncRecordEnvelope] = [:]
        var conflicts: [SyncConflictCopy] = []

        for record in local where immutableKinds.contains(record.resourceKind) {
            let key = immutableKey(record)
            acceptedByKey[key] = acceptedByKey[key].map { deterministicWinner($0, record) } ?? record
        }
        let immutableServer = Dictionary(
            server.filter { immutableKinds.contains($0.resourceKind) }.map { (immutableKey($0), $0) },
            uniquingKeysWith: deterministicWinner
        )
        acceptedByKey.merge(immutableServer, uniquingKeysWith: { _, server in server })

        let mutableLocal = Dictionary(
            local.filter { !immutableKinds.contains($0.resourceKind) }.map { (mutableKey($0), $0) },
            uniquingKeysWith: deterministicWinner
        )
        let mutableServer = Dictionary(
            server.filter { !immutableKinds.contains($0.resourceKind) }.map { (mutableKey($0), $0) },
            uniquingKeysWith: deterministicWinner
        )

        for key in Set(mutableLocal.keys).union(mutableServer.keys) {
            switch (mutableLocal[key], mutableServer[key]) {
            case let (local?, server?):
                acceptedByKey[key] = server
                if local.payload != server.payload || local.isTombstone != server.isTombstone {
                    conflicts.append(SyncConflictCopy(
                        resourceKind: local.resourceKind,
                        originalResourceID: local.id,
                        sourceDeviceID: local.deviceID,
                        payload: local.payload,
                        preservedAt: preservedAt,
                        wasTombstone: local.isTombstone,
                        acceptedWasTombstone: server.isTombstone
                    ))
                }
            case let (local?, nil): acceptedByKey[key] = local
            case let (nil, server?): acceptedByKey[key] = server
            case (nil, nil): break
            }
        }

        let accepted = acceptedByKey.values.sorted {
            ($0.resourceKind, $0.id, $0.deviceID, $0.order)
                < ($1.resourceKind, $1.id, $1.deviceID, $1.order)
        }
        return SyncMergeResult(accepted: accepted, conflictCopies: conflicts)
    }

    private static func immutableKey(_ value: SyncRecordEnvelope) -> String {
        "\(value.resourceKind):\(value.id)"
    }

    private static func mutableKey(_ value: SyncRecordEnvelope) -> String {
        "\(value.resourceKind):\(value.id)"
    }

    private static func deterministicWinner(
        _ first: SyncRecordEnvelope,
        _ second: SyncRecordEnvelope
    ) -> SyncRecordEnvelope {
        let lhs = (first.revision, first.deviceID, first.order)
        let rhs = (second.revision, second.deviceID, second.order)
        if lhs != rhs { return lhs > rhs ? first : second }
        if first.isTombstone != second.isTombstone { return first.isTombstone ? first : second }
        // Equal clocks can occur after recovery. Payload ordering provides a
        // stable tie break rather than depending on dictionary/delivery order.
        if first.payload != second.payload {
            return first.payload.lexicographicallyPrecedes(second.payload) ? second : first
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let firstAsset = (try? encoder.encode(first.asset)) ?? Data()
        let secondAsset = (try? encoder.encode(second.asset)) ?? Data()
        return firstAsset.lexicographicallyPrecedes(secondAsset) ? second : first
    }
}
