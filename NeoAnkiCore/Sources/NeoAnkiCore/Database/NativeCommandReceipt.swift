import CryptoKit
import Foundation

/// Durable confirmation of a native command. Stored in the existing ledger in
/// the mutation transaction, independently of HTTP clients and response bodies.
public struct NativeCommandReceipt: Codable, Sendable, Equatable {
    public let commandID: UUID
    public let committedAt: Date
    public let affectedCount: Int
    public let resultData: Data?
}

public struct NativeCommandContext: Sendable {
    public let id: UUID
    public let requestHash: String
    public let expectedCount: Int
    public static let clientID = UUID(uuidString: "C22FE710-A933-462C-A226-3FBAD42868B1")!
    public static let route = "native/v1/library-command"
    @TaskLocal public static var current: NativeCommandContext?

    public init(id: UUID = UUID(), operation: String, input: Data, expectedCount: Int = 1) {
        self.id = id
        self.expectedCount = expectedCount
        requestHash = SHA256.hash(data: Data(operation.utf8) + Data([0]) + input)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// A repeated command must recover its receipt rather than repeat its writes.
public struct NativeCommandAlreadyCommitted: Error, Sendable {
    public let receipt: NativeCommandReceipt
}

public extension ItemStore {
    func nativeCommandReceipt(_ context: NativeCommandContext) async throws -> NativeCommandReceipt? {
        try await database.nativeCommandReceipt(context)
    }
}

extension SQLiteDatabase {
    func nativeCommandReceipt(_ context: NativeCommandContext) throws -> NativeCommandReceipt? {
        guard let claim = try idempotencyClaim(clientID: NativeCommandContext.clientID,
            route: NativeCommandContext.route, key: context.id.uuidString,
            requestHash: context.requestHash) else { return nil }
        guard case let .completed(_, _, data) = claim else { throw DatabaseError.idempotencyConflict }
        return try JSONDecoder().decode(NativeCommandReceipt.self, from: data)
    }

    func recordNativeCommand(_ context: NativeCommandContext, count: Int?, resultData: Data?) throws {
        let receipt = NativeCommandReceipt(commandID: context.id, committedAt: .now,
            affectedCount: count ?? context.expectedCount, resultData: resultData)
        try execute("""
            INSERT INTO api_idempotency
              (client_id, route, idempotency_key, request_hash, state,
               response_status, response_body, created_at, completed_at)
            VALUES (?, ?, ?, ?, 'completed', 200, ?, ?, ?);
            """, bindings: [.text(NativeCommandContext.clientID.uuidString.lowercased()),
                .text(NativeCommandContext.route), .text(context.id.uuidString), .text(context.requestHash),
                .blob(try JSONEncoder().encode(receipt)),
                .double(receipt.committedAt.timeIntervalSince1970), .double(receipt.committedAt.timeIntervalSince1970)])
    }
}
