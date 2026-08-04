import Foundation

public enum IdempotencyClaim: Sendable, Equatable {
    case claimed(resultResourceID: String?)
    case pending(resultResourceID: String?)
    case completed(resultResourceID: String?, status: Int, responseBody: Data)
}

public extension ItemStore {
    /// Reads an existing claim without creating a pending ledger entry.
    /// This lets adapters honor failed preconditions without any persistence
    /// mutation while still serving completed replays before revalidation.
    func idempotencyClaim(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String
    ) async throws -> IdempotencyClaim? {
        try await database.idempotencyClaim(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash
        )
    }

    /// Claims one client/route/key tuple. The caller chooses any result resource
    /// identifier before mutation, allowing a retry to recover after a process
    /// exit between the domain commit and response persistence.
    func claimIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        resultResourceID: String? = nil,
        now: Date = .now
    ) async throws -> IdempotencyClaim {
        try await database.claimIdempotency(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash,
            resultResourceID: resultResourceID,
            now: now
        )
    }

    func completeIdempotency(
        clientID: UUID,
        route: String,
        key: String,
        requestHash: String,
        status: Int,
        responseBody: Data,
        now: Date = .now
    ) async throws {
        try await database.completeIdempotency(
            clientID: clientID,
            route: route,
            key: key,
            requestHash: requestHash,
            status: status,
            responseBody: responseBody,
            now: now
        )
    }

    @discardableResult
    func pruneIdempotencyRecords(before cutoff: Date) async throws -> Int {
        try await database.pruneIdempotencyRecords(before: cutoff)
    }
}
