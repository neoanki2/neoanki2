import Foundation
import SQLite3
import Testing
@testable import NeoAnkiCore

private func tempDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func makeStore() async throws -> ItemStore {
    let store = try ItemStore(databaseURL: tempDatabaseURL())
    try await store.bootstrap()
    return store
}

@Test func bootstrapSeedsBasicItemType() async throws {
    let store = try await makeStore()

    let itemType = try await store.defaultItemType()

    #expect(itemType.id == BuiltInItemTypes.basicID)
    #expect(itemType.name == "Basic")
    #expect(itemType.fields.map(\.name) == ["Front", "Back"])
    #expect(itemType.templates.count == 1)
    #expect(itemType.templates.first?.interaction == .reveal)
}

@Test func createItemPersistsItemAndGeneratedCards() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )

    let saved = try await store.createItem(item)
    let listed = try await store.listItems()

    #expect(saved.title == "Question")
    #expect(saved.subtitle == "Answer")
    #expect(saved.cardCount == 1)
    #expect(listed.count == 1)
    #expect(listed.first?.id == item.id)
    #expect(listed.first?.cardCount == 1)
}

@Test func deleteItemRemovesItemAndCards() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )

    _ = try await store.createItem(item)
    #expect(try await store.listItems().count == 1)
    #expect(try await store.dueCount() == 1)

    let deleted = try await store.deleteItem(id: item.id)
    #expect(deleted == true)
    #expect(try await store.listItems().isEmpty)
    #expect(try await store.dueCount() == 0)
    #expect(try await store.fetchItem(id: item.id) == nil)
    #expect(try await store.deleteItem(id: item.id) == false)
}

@Test func deleteItemTypeRemovesUnusedType() async throws {
    let store = try await makeStore()
    let itemType = try ItemTypeBuilder.makeItemType(
        name: "Temporary",
        fields: [
            FieldDef(name: "A", type: .text, isRequired: true),
            FieldDef(name: "B", type: .text, isRequired: true),
        ]
    )
    let created = try await store.createItemType(itemType)

    #expect(try await store.deleteItemType(id: created.id) == true)
    #expect(try await store.listItemTypes().map(\.name).contains("Temporary") == false)
}

@Test func deletingBasicStarterDoesNotReseedAfterReopen() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()

    #expect(try await store.deleteItemType(id: BuiltInItemTypes.basicID))
    #expect(try await store.listItemTypes().map(\.id) == [BuiltInItemTypes.clozeID])

    let reopened = try ItemStore(databaseURL: databaseURL)
    try await reopened.bootstrap()
    #expect(try await reopened.listItemTypes().map(\.id) == [BuiltInItemTypes.clozeID])
}

@Test func emptyStarterConfigurationIsPersistedAsCompletedFirstRun() async throws {
    let databaseURL = tempDatabaseURL()
    let unseeded = try ItemStore(databaseURL: databaseURL, starterItemTypes: [])
    try await unseeded.bootstrap()
    #expect(try await unseeded.listItemTypes().isEmpty)

    let reopenedWithDefaultStarter = try ItemStore(databaseURL: databaseURL)
    try await reopenedWithDefaultStarter.bootstrap()
    #expect(try await reopenedWithDefaultStarter.listItemTypes().isEmpty)
}

@Test func migrationMarksExistingLibrarySeededWithoutResurrectingBasic() async throws {
    let databaseURL = tempDatabaseURL()
    try createEmptyVersionFourDatabase(at: databaseURL)

    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()

    #expect(try await store.listItemTypes().isEmpty)
}

@Test func deleteItemTypeRejectsTypeWithItems() async throws {
    let store = try await makeStore()
    let itemType = try ItemTypeBuilder.makeItemType(
        name: "Occupied",
        fields: [
            FieldDef(name: "A", type: .text, isRequired: true),
            FieldDef(name: "B", type: .text, isRequired: true),
        ]
    )
    let created = try await store.createItemType(itemType)
    let item = Item(
        itemTypeID: created.id,
        fields: [
            FieldValue(fieldID: created.fields[0].id, value: .text("Front")),
            FieldValue(fieldID: created.fields[1].id, value: .text("Back")),
        ]
    )
    _ = try await store.createItem(item)

    await #expect(throws: DatabaseError.invalidItemType("Remove all items of this type before deleting it.")) {
        try await store.deleteItemType(id: created.id)
    }
}

@Test func itemsSurviveStoreReopen() async throws {
    let databaseURL = tempDatabaseURL()
    let itemID: UUID

    do {
        let store = try ItemStore(databaseURL: databaseURL)
        try await store.bootstrap()
        let itemType = try await store.defaultItemType()
        let item = Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
            ]
        )
        itemID = item.id
        _ = try await store.createItem(item)
    }

    let reopened = try ItemStore(databaseURL: databaseURL)
    try await reopened.bootstrap()
    let listed = try await reopened.listItems()

    #expect(listed.count == 1)
    #expect(listed.first?.id == itemID)
    #expect(listed.first?.title == "Front")
    #expect(listed.first?.subtitle == "Back")
}

@Test func requiredFieldsMustBePresent() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Only front")),
        ]
    )

    await #expect(throws: DatabaseError.requiredFieldEmpty("Back")) {
        try await store.createItem(item)
    }
}

@Test func itemTypeAndCardSyncRollBackTogether() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    var itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )
    _ = try await store.createItem(item)
    let reverse = try TemplateBuilder.makeRevealTemplate(
        name: "Reverse",
        promptFieldID: BuiltInItemTypes.backFieldID,
        answerFieldID: BuiltInItemTypes.frontFieldID,
        in: itemType
    )
    itemType.templates.append(reverse)
    try executeTestSQL(
        """
        CREATE TRIGGER force_card_insert_failure
        BEFORE INSERT ON cards
        BEGIN
            SELECT RAISE(ABORT, 'forced card sync failure');
        END;
        """,
        at: databaseURL
    )

    await #expect(throws: DatabaseError.self) {
        try await store.updateItemType(itemType)
    }

    let persistedType = try await store.defaultItemType()
    #expect(persistedType.templates.count == 1)
    #expect(try await store.listItems().first?.cardCount == 1)
}

@Test func batchImportRollsBackEveryRowOnDatabaseFailure() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    try executeTestSQL(
        """
        CREATE TRIGGER force_second_item_failure
        BEFORE INSERT ON items
        WHEN (SELECT COUNT(*) FROM items) >= 1
        BEGIN
            SELECT RAISE(ABORT, 'forced second item failure');
        END;
        """,
        at: databaseURL
    )
    let json = """
    {
      "itemType": "Basic",
      "rows": [
        { "Front": "One", "Back": "1" },
        { "Front": "Two", "Back": "2" }
      ]
    }
    """.data(using: .utf8)!

    await #expect(throws: DatabaseError.self) {
        try await store.importItems(from: json, adapter: JSONImportAdapter())
    }

    #expect(try await store.listItems().isEmpty)
    #expect(try await store.dueCount() == 0)
}

@Test func fetchItemReturnsItemAndType() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )
    _ = try await store.createItem(item)

    let fetched = try await store.fetchItem(id: item.id)
    #expect(fetched?.item.id == item.id)
    #expect(fetched?.itemType.id == itemType.id)
    #expect(fetched?.item.value(for: BuiltInItemTypes.frontFieldID) == .text("Question"))
}

private func executeTestSQL(_ sql: String, at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK, let db else {
        throw DatabaseError.openFailed("Could not open test database.")
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}

@Test func fetchItemReturnsNilForMissingID() async throws {
    let store = try await makeStore()
    #expect(try await store.fetchItem(id: UUID()) == nil)
}

@Test func migratesLegacyNoteSchema() async throws {
    let databaseURL = tempDatabaseURL()
    try createLegacyNoteDatabase(at: databaseURL)

    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()

    let items = try await store.listItems()
    #expect(items.count == 1)
    #expect(items.first?.title == "Legacy front")
    #expect(items.first?.subtitle == "Legacy back")
}

@Test func persistedProfileParametersLoadAndDriveScheduling() async throws {
    let databaseURL = tempDatabaseURL()
    var weights = FSRSScheduler.Parameters.defaultWeights
    weights[0] = 2.5
    let expected = FSRSScheduler.Parameters(weights: weights, enableFuzz: false)

    let database = try SQLiteDatabase(path: databaseURL)
    try await database.migrate()
    try await database.saveSchedulerParameters(
        expected,
        profileID: "learner-a",
        optimizedAt: Date(timeIntervalSince1970: 100),
        sampleCount: 120,
        logLoss: 0.4
    )

    let store = try ItemStore(databaseURL: databaseURL, profileID: "learner-a")
    try await store.bootstrap()
    #expect(await store.schedulingParameters() == expected)

    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
        ]
    )
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.createItem(item, now: now)
    let card = try #require(await store.fetchDueCards(asOf: now).first)
    let memory = try await store.submitReview(cardID: card.id, rating: .again, now: now)

    #expect(memory.stability == 2.5)
}

@Test func persistedFSRS5ProfileMigratesToFSRS6AcrossRelaunch() async throws {
    let databaseURL = tempDatabaseURL()
    let database = try SQLiteDatabase(path: databaseURL)
    try await database.migrate()
    let legacyWeights = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046,
        1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315,
        2.9898, 0.51655, 0.6621,
    ]
    let json = try JSONSerialization.data(withJSONObject: [
        "weights": legacyWeights,
        "requestRetention": 0.9,
        "maximumInterval": 36_500,
        "enableFuzz": false,
    ])
    let hex = json.map { String(format: "%02x", $0) }.joined()
    try executeTestSQL(
        """
        INSERT INTO scheduler_params
            (profile_id, parameters, optimized_at, sample_count, log_loss)
        VALUES ('legacy-v5', X'\(hex)', 100, 120, 0.4);
        """,
        at: databaseURL
    )

    let firstOpen = try ItemStore(databaseURL: databaseURL, profileID: "legacy-v5")
    try await firstOpen.bootstrap()
    let first = await firstOpen.schedulingParameters()
    #expect(first.weights.count == 21)
    #expect(Array(first.weights.prefix(19)) == legacyWeights)
    #expect(first.weights[19] == 0)
    #expect(first.weights[20] == 0.5)

    let reopened = try ItemStore(databaseURL: databaseURL, profileID: "legacy-v5")
    try await reopened.bootstrap()
    #expect(await reopened.schedulingParameters() == first)
}

@Test func revertMarksReviewInactiveWithoutDeletingHistory() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
        ]
    )
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.createItem(item, now: now)
    let card = try #require(await store.fetchDueCards(asOf: now).first)

    let submission = try await store.submitReviewWithReceipt(
        cardID: card.id,
        rating: .good,
        now: now
    )
    try await store.revertReview(reviewLogID: submission.reviewLogID, now: now)

    #expect(try await store.reviewLogCount(for: card.id) == 0)
    #expect(try reviewLogRowCount(at: databaseURL, cardID: card.id) == 1)
}

@Test func immediateRepairStatePersistsAcrossReopenAndUndoRestoresExactState() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let itemType = try await store.defaultItemType()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
            ]
        ),
        now: start
    )
    let original = try #require(await store.fetchDueCards(asOf: start).first)

    let first = try await store.submitReviewWithReceipt(
        cardID: original.id,
        rating: .again,
        now: start
    )
    #expect(first.memory.phase == .learning)
    #expect(first.memory.stepIndex == 0)
    #expect(first.memory.due == start)
    #expect(try await store.fetchDueCards(asOf: start).count == 1)

    let reopened = try ItemStore(databaseURL: databaseURL)
    try await reopened.bootstrap()
    let due = try #require(
        await reopened.fetchDueCards(asOf: start).first
    )
    #expect(due.card.memory == first.memory)

    let second = try await reopened.submitReviewWithReceipt(
        cardID: due.id,
        rating: .again,
        now: start.addingTimeInterval(30)
    )
    #expect(second.memory.lapses == 0)
    let logs = try await SQLiteDatabase(path: databaseURL).fetchActiveReviewLogs()
    #expect(logs.count == 2)
    #expect(logs[1].scheduledDays == 0)
    #expect(abs(logs[1].elapsedDays - (30 / 86_400)) < 1e-12)
    #expect(logs[1].phaseBefore == .learning)

    try await reopened.revertReview(
        reviewLogID: second.reviewLogID,
        now: start.addingTimeInterval(30)
    )
    let restored = try #require(
        await reopened.fetchDueCards(asOf: start.addingTimeInterval(30)).first
    )
    #expect(restored.card.memory == first.memory)
}

@Test func reviewAgainEntersImmediateRelearningThroughStore() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let itemType = try await store.defaultItemType()
    let now = Date(timeIntervalSinceReferenceDate: 806_926_474.635_533)
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
            ]
        ),
        now: now.addingTimeInterval(-3_600)
    )
    let card = try #require(await store.fetchDueCards(asOf: now).first)
    let reviewMemory = MemoryState(
        stability: 0.006940758044349528,
        difficulty: 9.955935509193166,
        due: Date(timeIntervalSinceReferenceDate: 806_923_269.169_737),
        lastReview: Date(timeIntervalSinceReferenceDate: 806_922_669.488_242),
        reps: 7,
        lapses: 0,
        phase: .review
    )
    try await SQLiteDatabase(path: databaseURL).updateCardMemory(card.id, memory: reviewMemory)

    let submission = try await store.submitReviewWithReceipt(
        cardID: card.id,
        rating: .again,
        now: now
    )

    #expect(submission.memory.phase == .relearning)
    #expect(submission.memory.due == now)
    #expect(submission.memory.lapses == 1)
    let persisted = try #require(try await SQLiteDatabase(path: databaseURL).fetchCard(id: card.id))
    #expect(persisted.memory == submission.memory)
}

@Test func optimizationPersistsThroughStoreAPIAndReopen() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL, profileID: "learner-b")
    try await store.bootstrap()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
        ]
    )
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.createItem(item, now: start)
    let card = try #require(await store.fetchDueCards(asOf: start).first)
    let database = try SQLiteDatabase(path: databaseURL)

    for index in 0..<130 {
        let rating: ReviewRating = index == 0 || index % 5 != 0 ? .good : .again
        try await database.insertReviewLog(
            ReviewLog(
                cardID: card.id,
                reviewedAt: start.addingTimeInterval(Double(index * 12) * 86_400),
                rating: rating,
                elapsedDays: index == 0 ? 0 : 12,
                scheduledDays: index == 0 ? 0 : 12,
                phaseBefore: index == 0 ? .new : .review,
                durationMs: 1_000
            ),
            memoryBefore: .new(due: start)
        )
    }

    let result = try await store.optimizeScheduling(minimumObservations: 100)
    #expect(result.improved)
    #expect(result.optimizedLoss < result.previousLoss)

    let reopened = try ItemStore(databaseURL: databaseURL, profileID: "learner-b")
    try await reopened.bootstrap()
    #expect(await reopened.schedulingParameters() == result.parameters)
}

@Test func automaticOptimizationFitsOnceAndThenWaitsForNewHistory() async throws {
    let databaseURL = tempDatabaseURL()
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let itemType = try await store.defaultItemType()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
            ]
        ),
        now: start
    )
    let card = try #require(await store.fetchDueCards(asOf: start).first).card

    // Too little history to fit: the automatic path must not touch parameters
    // and must not record an attempt it never made.
    let untuned = await store.schedulingParameters()
    #expect(try await store.optimizeSchedulingIfNeeded(now: start) == nil)
    #expect(await store.schedulingParameters() == untuned)
    #expect(try await store.lastOptimizationAttempt() == nil)

    for index in 0..<130 {
        let rating: ReviewRating = index == 0 || index % 5 != 0 ? .good : .again
        _ = try await store.submitReview(
            cardID: card.id,
            rating: rating,
            now: start.addingTimeInterval(Double(index * 12) * 86_400),
            durationMs: 1_000
        )
    }
    let end = start.addingTimeInterval(130 * 12 * 86_400)

    let result = try #require(try await store.optimizeSchedulingIfNeeded(now: end))
    #expect(result.improved)
    #expect(await store.schedulingParameters() == result.parameters)
    let attempt = try #require(await store.lastOptimizationAttempt())
    #expect(attempt.reviewLogCount == 130)
    #expect(attempt.attemptedAt == end)

    // A second call with no new reviews must not refit.
    #expect(try await store.optimizeSchedulingIfNeeded(now: end) == nil)
    #expect(await store.schedulingParameters() == result.parameters)

    // Each profile fits its own weights, so a different profile in the same
    // library starts with no attempt of its own.
    let otherProfile = try ItemStore(databaseURL: databaseURL, profileID: "learner-c")
    try await otherProfile.bootstrap()
    #expect(try await otherProfile.lastOptimizationAttempt() == nil)
}

private func reviewLogRowCount(at url: URL, cardID: UUID) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let db else {
        throw DatabaseError.openFailed("Could not inspect test database.")
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        db,
        "SELECT COUNT(*) FROM review_logs WHERE card_id = ?;",
        -1,
        &statement,
        nil
    ) == SQLITE_OK,
          let statement else {
        throw DatabaseError.queryFailed("Could not inspect test database.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_text(
        statement,
        1,
        cardID.uuidString,
        -1,
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    ) == SQLITE_OK else {
        throw DatabaseError.queryFailed("Could not bind test card ID.")
    }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw DatabaseError.queryFailed("Could not inspect test database.")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func createLegacyNoteDatabase(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK, let db else {
        throw DatabaseError.openFailed("Could not create legacy test database.")
    }
    defer { sqlite3_close(db) }

    let statements = [
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version (version) VALUES (2);
        """,
        """
        CREATE TABLE note_types (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            definition BLOB NOT NULL
        );
        """,
        """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY NOT NULL,
            note_type_id TEXT NOT NULL REFERENCES note_types(id),
            fields BLOB NOT NULL,
            tags BLOB NOT NULL,
            deck_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE cards (
            id TEXT PRIMARY KEY NOT NULL,
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            template_id TEXT NOT NULL,
            skill BLOB NOT NULL,
            memory BLOB NOT NULL,
            is_suspended INTEGER NOT NULL DEFAULT 0,
            deck_id TEXT,
            due_at REAL NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE review_logs (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
            reviewed_at REAL NOT NULL,
            log BLOB NOT NULL
        );
        CREATE INDEX idx_review_logs_card_id ON review_logs(card_id);
        """,
    ]

    for sql in statements {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    let itemType = BuiltInItemTypes.basic
    let itemTypeData = try JSONEncoder().encode(itemType)
    let itemID = UUID()
    let cardID = UUID()
    let templateID = itemType.templates[0].id
    let fields = [
        FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Legacy front")),
        FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Legacy back")),
    ]
    let fieldsData = try JSONEncoder().encode(fields)
    let tagsData = try JSONEncoder().encode([String]())
    let skillData = try JSONEncoder().encode(Skill(input: .text, output: .text, operation: .recognize))
    let memory = MemoryState(due: Date(timeIntervalSince1970: 1_700_000_000))
    let memoryData = try JSONEncoder().encode(memory)

    try bindAndRun(
        db,
        sql: "INSERT INTO note_types (id, name, definition) VALUES (?, ?, ?);",
        itemType.id.uuidString,
        itemType.name,
        itemTypeData
    )
    try bindAndRun(
        db,
        sql: """
        INSERT INTO notes (id, note_type_id, fields, tags, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """,
        itemID.uuidString,
        itemType.id.uuidString,
        fieldsData,
        tagsData,
        1_700_000_000.0,
        1_700_000_000.0
    )
    try bindAndRun(
        db,
        sql: """
        INSERT INTO cards (id, note_id, template_id, skill, memory, due_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """,
        cardID.uuidString,
        itemID.uuidString,
        templateID.uuidString,
        skillData,
        memoryData,
        1_700_000_000.0
    )
}

private func createEmptyVersionFourDatabase(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK, let db else {
        throw DatabaseError.openFailed("Could not create version four test database.")
    }
    defer { sqlite3_close(db) }

    let sql = """
    CREATE TABLE schema_version (version INTEGER NOT NULL);
    INSERT INTO schema_version (version) VALUES (4);
    CREATE TABLE item_types (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        definition BLOB NOT NULL
    );
    CREATE TABLE cards (
        id TEXT PRIMARY KEY NOT NULL
    );
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}

private func bindAndRun(
    _ db: OpaquePointer,
    sql: String,
    _ text1: String,
    _ text2: String,
    _ blob: Data
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, text1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, text2, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    blob.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}

private func bindAndRun(
    _ db: OpaquePointer,
    sql: String,
    _ text1: String,
    _ text2: String,
    _ blob1: Data,
    _ blob2: Data,
    _ double1: Double,
    _ double2: Double
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, text1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, text2, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    blob1.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    blob2.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    sqlite3_bind_double(statement, 5, double1)
    sqlite3_bind_double(statement, 6, double2)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}

private func bindAndRun(
    _ db: OpaquePointer,
    sql: String,
    _ text1: String,
    _ text2: String,
    _ text3: String,
    _ blob1: Data,
    _ blob2: Data,
    _ double1: Double
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, text1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, text2, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 3, text3, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    blob1.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    blob2.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 5, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    sqlite3_bind_double(statement, 6, double1)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
    }
}
