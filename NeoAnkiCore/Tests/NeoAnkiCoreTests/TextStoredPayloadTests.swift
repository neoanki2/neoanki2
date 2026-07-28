import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

/// A `BLOB` column has blob affinity, so SQLite stores whatever storage class a
/// writer bound. External repair tooling that binds the same JSON as a string
/// leaves a text-typed row behind, and reading it must keep working: these rows
/// are still counted as due, so refusing to decode them made a whole study
/// session fail while the scope home kept advertising cards to study.

private func payloadDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-payload-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func payloadItem() -> Item {
    Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
        ]
    )
}

/// Rewrites a card's encoded columns as text without altering their contents.
private func rewriteEncodedColumnsAsText(at url: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK, let handle else {
        throw DatabaseError.openFailed("Could not open test database.")
    }
    defer { sqlite3_close(handle) }

    let sql = """
        UPDATE cards SET
            memory = CAST(memory AS TEXT),
            skill = CAST(skill AS TEXT);
        UPDATE items SET
            fields = CAST(fields AS TEXT),
            tags = CAST(tags AS TEXT);
        """
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(handle)))
    }
}

@Test func textStoredCardPayloadsStayStudyable() async throws {
    let databaseURL = payloadDatabaseURL()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    _ = try await store.createItem(payloadItem(), now: now)
    #expect(try await store.fetchDueCards(asOf: now).count == 1)

    try rewriteEncodedColumnsAsText(at: databaseURL)

    let reopened = try ItemStore(databaseURL: databaseURL)
    try await reopened.bootstrap()

    // The count and the queue have to agree, or the session opens empty on a
    // scope that still says a card is due.
    let due = try await reopened.fetchDueCards(asOf: now)
    #expect(try await reopened.dueCount(asOf: now) == 1)
    #expect(due.count == 1)
    #expect(due.first?.card.memory.phase == .new)
    #expect(due.first?.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Front"))

    // Grading a repaired card must still round-trip through the scheduler.
    let card = try #require(due.first)
    _ = try await reopened.submitReview(cardID: card.id, rating: .good, now: now)
    #expect(try await reopened.reviewLogCount(for: card.id) == 1)
}
