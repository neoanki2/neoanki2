import Foundation
import NeoAnkiCore
import NeoAnkiTemplateMigration
import SQLite3
import Testing

@Test("Template migrator plans, applies atomically, and preserves library identities")
func templateMigratorPreservesIdentities() throws {
    let fixture = try LegacyMigrationFixture(corruptReference: false)
    defer { fixture.remove() }

    let plan = try TemplateDefinitionMigrator.plan(databaseURL: fixture.url)
    #expect(!plan.alreadyMigrated)
    #expect(plan.itemTypeCount == 1)
    #expect(plan.mappings.map(\.layout) == [.focus])

    _ = try TemplateDefinitionMigrator.apply(databaseURL: fixture.url)
    let verified = try TemplateDefinitionMigrator.verify(databaseURL: fixture.url)
    #expect(verified.itemTypeCount == 1)
    #expect(verified.itemCount == 1)
    #expect(verified.cardCount == 1)
    #expect(verified.reviewLogCount == 1)
    #expect(verified.responseCount == 1)
    #expect(verified.mediaCount == 1)
    #expect(verified.quarantineCount == 0)
    #expect(try fixture.scalar("SELECT value FROM app_metadata WHERE key = 'template_definition_format';") == "2")
    #expect(try fixture.scalar("SELECT id FROM items;") == fixture.itemID)
    #expect(try fixture.scalar("SELECT id FROM cards;") == fixture.cardID)
    #expect(try fixture.scalar("SELECT id FROM review_logs;") == fixture.reviewID)
}

@Test("A corrupt legacy reference rolls migration back without a format marker")
func templateMigratorRollsBack() throws {
    let fixture = try LegacyMigrationFixture(corruptReference: true)
    defer { fixture.remove() }
    let before = try fixture.definition()

    #expect(throws: (any Error).self) {
        try TemplateDefinitionMigrator.apply(databaseURL: fixture.url)
    }
    #expect(try fixture.scalar("SELECT value FROM app_metadata WHERE key = 'template_definition_format';") == nil)
    #expect(try fixture.definition() == before)
    #expect(try fixture.scalar("SELECT COUNT(*) FROM quarantined_item_type_definitions;") == "0")
}

private struct LegacyMigrationItemType: Encodable {
    let id: UUID
    let name: String
    let fields: [FieldDef]
    let templates: [LegacyMigrationTemplate]
}

private struct LegacyMigrationTemplate: Encodable {
    let id: UUID
    let name: String
    let prompt: Side
    let answer: Side
    let interaction: Interaction
    let skill: Skill
    let generateWhen: SlotCondition?
}

private final class LegacyMigrationFixture {
    let url: URL
    let itemID = "10000000-0000-4000-8000-000000000001"
    let cardID = "10000000-0000-4000-8000-000000000002"
    let reviewID = "10000000-0000-4000-8000-000000000003"
    private var handle: OpaquePointer?

    init(corruptReference: Bool) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-template-migration-\(UUID().uuidString).sqlite")
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw FixtureError.sqlite }
        try execute("""
        CREATE TABLE app_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE item_types(id TEXT PRIMARY KEY, name TEXT NOT NULL, definition BLOB NOT NULL);
        CREATE TABLE portable_item_type_mappings(origin_library_id TEXT, origin_type_id TEXT, schema_digest TEXT, local_type_id TEXT);
        CREATE TABLE items(id TEXT PRIMARY KEY);
        CREATE TABLE cards(id TEXT PRIMARY KEY, template_id TEXT NOT NULL);
        CREATE TABLE review_logs(id TEXT PRIMARY KEY);
        CREATE TABLE study_responses(id TEXT PRIMARY KEY);
        CREATE TABLE media_assets(hash TEXT PRIMARY KEY);
        CREATE TABLE quarantined_item_type_definitions(item_type_id TEXT);
        """)

        let front = FieldDef(name: "Front", type: .text, isRequired: true)
        let back = FieldDef(name: "Back", type: .text, isRequired: true)
        let templateID = UUID()
        let promptID = corruptReference ? UUID() : front.id
        let type = LegacyMigrationItemType(
            id: UUID(),
            name: "Legacy",
            fields: [front, back],
            templates: [LegacyMigrationTemplate(
                id: templateID,
                name: "Card",
                prompt: Side(slots: [Slot(source: .field(promptID))]),
                answer: Side(slots: [Slot(source: .field(back.id))]),
                interaction: .reveal,
                skill: Skill(input: .text, output: .text, operation: .recall),
                generateWhen: nil
            )]
        )
        let data = try JSONEncoder().encode(type)
        try insertDefinition(id: type.id.uuidString, data: data)
        try execute("INSERT INTO items VALUES ('\(itemID)');")
        try execute("INSERT INTO cards VALUES ('\(cardID)', '\(templateID.uuidString)');")
        try execute("INSERT INTO review_logs VALUES ('\(reviewID)');")
        try execute("INSERT INTO study_responses VALUES ('10000000-0000-4000-8000-000000000004');")
        try execute("INSERT INTO media_assets VALUES ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');")
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func remove() {
        if let handle { sqlite3_close(handle); self.handle = nil }
        try? FileManager.default.removeItem(at: url)
    }

    func definition() throws -> Data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT definition FROM item_types LIMIT 1;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { throw FixtureError.sqlite }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func scalar(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_INTEGER: return String(sqlite3_column_int64(statement, 0))
        case SQLITE_TEXT: return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        default: return nil
        }
    }

    private func insertDefinition(id: String, data: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO item_types VALUES (?, 'Legacy', ?);", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            sqlite3_free(error)
            throw FixtureError.sqlite
        }
    }
}

private enum FixtureError: Error { case sqlite }
