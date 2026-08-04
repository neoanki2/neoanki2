import CryptoKit
import Foundation
import Testing
@testable import NeoAnkiCore

private func idempotencyDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-idempotency-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("library.sqlite")
}

private func requestHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test func idempotencyClaimConflictCompletionAndRestartAreDurable() async throws {
    let url = idempotencyDatabaseURL()
    let store = try ItemStore(databaseURL: url, starterItemTypes: [])
    try await store.bootstrap()
    let clientID = UUID()
    let resourceID = UUID().uuidString.lowercased()
    let hash = requestHash("same request")
    let baseline = try await store.currentChangeCursor()

    #expect(
        try await store.claimIdempotency(
            clientID: clientID,
            route: "POST /v1/decks",
            key: "retry-key",
            requestHash: hash,
            resultResourceID: resourceID
        ) == .claimed(resultResourceID: resourceID)
    )
    #expect(
        try await store.claimIdempotency(
            clientID: clientID,
            route: "POST /v1/decks",
            key: "retry-key",
            requestHash: hash,
            resultResourceID: "ignored"
        ) == .pending(resultResourceID: resourceID)
    )
    await #expect(throws: DatabaseError.idempotencyConflict) {
        try await store.claimIdempotency(
            clientID: clientID,
            route: "POST /v1/decks",
            key: "retry-key",
            requestHash: requestHash("different request"),
            resultResourceID: resourceID
        )
    }

    let response = Data("{\"id\":\"\(resourceID)\"}".utf8)
    try await store.completeIdempotency(
        clientID: clientID,
        route: "POST /v1/decks",
        key: "retry-key",
        requestHash: hash,
        status: 201,
        responseBody: response
    )

    let reopened = try ItemStore(databaseURL: url, starterItemTypes: [])
    try await reopened.bootstrap()
    #expect(
        try await reopened.claimIdempotency(
            clientID: clientID,
            route: "POST /v1/decks",
            key: "retry-key",
            requestHash: hash
        ) == .completed(
            resultResourceID: resourceID,
            status: 201,
            responseBody: response
        )
    )
    #expect(try await reopened.currentChangeCursor() == baseline)
}

@Test func idempotencyScopeAndRetentionAreExact() async throws {
    let store = try ItemStore(databaseURL: idempotencyDatabaseURL(), starterItemTypes: [])
    try await store.bootstrap()
    let firstClient = UUID()
    let secondClient = UUID()
    let old = Date(timeIntervalSince1970: 1_000)
    let recent = Date(timeIntervalSince1970: 2_000)

    _ = try await store.claimIdempotency(
        clientID: firstClient,
        route: "POST /v1/items",
        key: "same",
        requestHash: requestHash("one"),
        now: old
    )
    _ = try await store.claimIdempotency(
        clientID: secondClient,
        route: "POST /v1/items",
        key: "same",
        requestHash: requestHash("two"),
        now: recent
    )

    #expect(try await store.pruneIdempotencyRecords(before: recent) == 1)
    #expect(
        try await store.claimIdempotency(
            clientID: firstClient,
            route: "POST /v1/items",
            key: "same",
            requestHash: requestHash("replacement")
        ) == .claimed(resultResourceID: nil)
    )
    #expect(
        try await store.claimIdempotency(
            clientID: secondClient,
            route: "POST /v1/items",
            key: "same",
            requestHash: requestHash("two")
        ) == .pending(resultResourceID: nil)
    )
}
