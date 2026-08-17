import CryptoKit
import Foundation
import NeoAnkiCore
import SQLite3

public enum TemplateDefinitionMigrationError: Error, LocalizedError {
    case database(String)
    case unsupportedFormat(String?)
    case corruptDefinition(String)
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case let .database(message): message
        case let .unsupportedFormat(value):
            "Unsupported template_definition_format marker: \(value ?? "missing after migration")."
        case let .corruptDefinition(message): "Invalid legacy item-type definition: \(message)"
        case let .verification(message): "Migration verification failed: \(message)"
        }
    }
}

public struct TemplateMigrationMapping: Sendable, Equatable {
    public let itemTypeID: UUID
    public let templateID: UUID
    public let layout: CardLayoutID
    public let questionCount: Int
    public let answerCount: Int
    public let supportingCount: Int
    public let mediaCount: Int
}

public struct TemplateMigrationReport: Sendable, Equatable {
    public let alreadyMigrated: Bool
    public let itemTypeCount: Int
    public let templateCount: Int
    public let mappings: [TemplateMigrationMapping]
}

public struct TemplateMigrationVerification: Sendable, Equatable {
    public let itemTypeCount: Int
    public let itemCount: Int
    public let cardCount: Int
    public let reviewLogCount: Int
    public let responseCount: Int
    public let mediaCount: Int
    public let quarantineCount: Int
}

/// One-shot format migration. This target is linked only by the headless
/// migrator executable; the application runtime has no legacy decoder.
public enum TemplateDefinitionMigrator {
    public static let metadataKey = "template_definition_format"
    public static let currentFormat = "2"

    public static func plan(databaseURL: URL) throws -> TemplateMigrationReport {
        let database = try MigrationDatabase(url: databaseURL, readOnly: true)
        defer { database.close() }
        let marker = try database.metadataValue(for: metadataKey)
        if marker == currentFormat {
            let current = try loadCurrentDefinitions(database)
            return report(for: current, alreadyMigrated: true)
        }
        guard marker == nil else { throw TemplateDefinitionMigrationError.unsupportedFormat(marker) }
        return report(for: try loadMigratedDefinitions(database), alreadyMigrated: false)
    }

    @discardableResult
    public static func apply(databaseURL: URL) throws -> TemplateMigrationReport {
        let database = try MigrationDatabase(url: databaseURL, readOnly: false)
        defer { database.close() }
        try database.execute("BEGIN IMMEDIATE;")
        do {
            let marker = try database.metadataValue(for: metadataKey)
            if marker == currentFormat {
                let current = try loadCurrentDefinitions(database)
                try database.execute("COMMIT;")
                return report(for: current, alreadyMigrated: true)
            }
            guard marker == nil else {
                throw TemplateDefinitionMigrationError.unsupportedFormat(marker)
            }

            let identities = try identitySnapshot(database)
            let quarantineCount = try database.count("quarantined_item_type_definitions")
            let migrated = try loadMigratedDefinitions(database)
            let encoder = JSONEncoder()
            for itemType in migrated {
                let data = try encoder.encode(itemType)
                try database.execute(
                    "UPDATE item_types SET name = ?, definition = ? WHERE id = ?;",
                    bindings: [.text(itemType.name), .blob(data), .text(itemType.id.uuidString)]
                )
                let digest = try itemType.portableSchemaDigest()
                try database.execute(
                    "UPDATE portable_item_type_mappings SET schema_digest = ? WHERE local_type_id = ?;",
                    bindings: [.text(digest), .text(itemType.id.uuidString)]
                )
            }
            try database.execute(
                "INSERT INTO app_metadata(key, value) VALUES (?, ?);",
                bindings: [.text(metadataKey), .text(currentFormat)]
            )

            guard identities == (try identitySnapshot(database)) else {
                throw TemplateDefinitionMigrationError.verification(
                    "item, template owner, card, review, response, or media identities changed"
                )
            }
            guard quarantineCount == (try database.count("quarantined_item_type_definitions")) else {
                throw TemplateDefinitionMigrationError.verification("quarantine records changed")
            }
            _ = try loadCurrentDefinitions(database)
            try database.execute("COMMIT;")
            return report(for: migrated, alreadyMigrated: false)
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    public static func verify(databaseURL: URL) throws -> TemplateMigrationVerification {
        let database = try MigrationDatabase(url: databaseURL, readOnly: true)
        defer { database.close() }
        guard try database.metadataValue(for: metadataKey) == currentFormat else {
            throw TemplateDefinitionMigrationError.unsupportedFormat(
                try database.metadataValue(for: metadataKey)
            )
        }
        let definitions = try loadCurrentDefinitions(database)
        let templateIDs = Set(definitions.flatMap(\.templates).map { $0.id.uuidString.lowercased() })
        for value in try database.strings("SELECT lower(template_id) FROM cards;")
            where !templateIDs.contains(value) {
            throw TemplateDefinitionMigrationError.verification(
                "card references missing template \(value)"
            )
        }
        let integrity = try database.strings("PRAGMA integrity_check;")
        guard integrity == ["ok"] else {
            throw TemplateDefinitionMigrationError.verification("SQLite integrity_check failed")
        }
        return TemplateMigrationVerification(
            itemTypeCount: try database.count("item_types"),
            itemCount: try database.count("items"),
            cardCount: try database.count("cards"),
            reviewLogCount: try database.count("review_logs"),
            responseCount: try database.count("study_responses"),
            mediaCount: try database.count("media_assets"),
            quarantineCount: try database.count("quarantined_item_type_definitions")
        )
    }

    private static func loadMigratedDefinitions(_ database: MigrationDatabase) throws -> [ItemType] {
        let decoder = JSONDecoder()
        return try database.definitionRows().map { row in
            do {
                let legacy = try decoder.decode(LegacyItemType.self, from: row.data)
                guard legacy.id.uuidString.caseInsensitiveCompare(row.id) == .orderedSame else {
                    throw TemplateDefinitionMigrationError.corruptDefinition(
                        "persisted ID does not match definition ID"
                    )
                }
                let templates = legacy.templates.map { template -> Template in
                    let mapped = TemplateCompositionMigration.map(
                        prompt: template.prompt,
                        answer: template.answer,
                        interaction: template.interaction,
                        fields: legacy.fields
                    )
                    let components = mapped.components.enumerated().map { ordinal, component in
                        TemplateComponent(
                            id: deterministicComponentID(templateID: template.id, ordinal: ordinal),
                            region: component.region,
                            purpose: component.purpose,
                            source: component.source,
                            presentation: component.presentation
                        )
                    }
                    return Template(
                        id: template.id,
                        name: template.name,
                        layout: mapped.layout,
                        components: components,
                        interaction: template.interaction,
                        skill: template.skill,
                        generateWhen: template.generateWhen
                    )
                }
                let itemType = ItemType(
                    id: legacy.id,
                    name: legacy.name,
                    fields: legacy.fields,
                    templates: templates
                )
                try ItemTypeValidation.validate(itemType)
                return itemType
            } catch let error as TemplateDefinitionMigrationError {
                throw error
            } catch {
                throw TemplateDefinitionMigrationError.corruptDefinition(
                    "\(row.id): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func loadCurrentDefinitions(_ database: MigrationDatabase) throws -> [ItemType] {
        let decoder = JSONDecoder()
        return try database.definitionRows().map { row in
            do {
                let itemType = try decoder.decode(ItemType.self, from: row.data)
                guard itemType.id.uuidString.caseInsensitiveCompare(row.id) == .orderedSame else {
                    throw TemplateDefinitionMigrationError.verification(
                        "persisted item-type ID does not match definition"
                    )
                }
                try ItemTypeValidation.validate(itemType)
                return itemType
            } catch let error as TemplateDefinitionMigrationError {
                throw error
            } catch {
                throw TemplateDefinitionMigrationError.verification(
                    "could not decode item type \(row.id): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func report(
        for itemTypes: [ItemType],
        alreadyMigrated: Bool
    ) -> TemplateMigrationReport {
        let mappings = itemTypes.flatMap { itemType in
            itemType.templates.map { template in
                TemplateMigrationMapping(
                    itemTypeID: itemType.id,
                    templateID: template.id,
                    layout: template.layout,
                    questionCount: template.components.count { $0.purpose == .question },
                    answerCount: template.components.count { $0.purpose == .expectedAnswer },
                    supportingCount: template.components.count { $0.purpose == .supporting },
                    mediaCount: template.components.count { $0.region == .media }
                )
            }
        }
        return TemplateMigrationReport(
            alreadyMigrated: alreadyMigrated,
            itemTypeCount: itemTypes.count,
            templateCount: mappings.count,
            mappings: mappings
        )
    }

    private static func deterministicComponentID(templateID: UUID, ordinal: Int) -> UUID {
        let digest = SHA256.hash(
            data: Data("neoanki-template-component-v1|\(templateID.uuidString.lowercased())|\(ordinal)".utf8)
        )
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func identitySnapshot(_ database: MigrationDatabase) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (table, column) in [
            ("item_types", "id"), ("items", "id"), ("cards", "id"),
            ("review_logs", "id"), ("study_responses", "id"), ("media_assets", "hash"),
        ] {
            result[table] = try database.strings("SELECT \(column) FROM \(table) ORDER BY \(column);")
        }
        return result
    }
}

private struct LegacyItemType: Decodable {
    let id: UUID
    let name: String
    let fields: [FieldDef]
    let templates: [LegacyTemplate]
}

private struct LegacyTemplate: Decodable {
    let id: UUID
    let name: String
    let prompt: Side
    let answer: Side
    let interaction: Interaction
    let skill: Skill
    let generateWhen: SlotCondition?
}

private final class MigrationDatabase {
    enum Binding { case text(String), blob(Data) }
    struct DefinitionRow { let id: String; let data: Data }
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            throw TemplateDefinitionMigrationError.database("Could not open \(url.path).")
        }
        try execute("PRAGMA foreign_keys = ON;")
        sqlite3_busy_timeout(handle, 5_000)
    }

    func close() { if let handle { sqlite3_close(handle); self.handle = nil } }

    func metadataValue(for key: String) throws -> String? {
        try rows(
            "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;",
            bindings: [.text(key)]
        ).first?.first as? String
    }

    func definitionRows() throws -> [DefinitionRow] {
        try rows("SELECT id, definition FROM item_types ORDER BY id;").map { values in
            guard values.count == 2, let id = values[0] as? String else {
                throw TemplateDefinitionMigrationError.database("Malformed item_types row.")
            }
            let data: Data
            if let blob = values[1] as? Data { data = blob }
            else if let text = values[1] as? String { data = Data(text.utf8) }
            else { throw TemplateDefinitionMigrationError.database("Missing item-type definition.") }
            return DefinitionRow(id: id, data: data)
        }
    }

    func count(_ table: String) throws -> Int {
        guard let value = try rows("SELECT COUNT(*) FROM \(table);").first?.first as? Int64 else {
            throw TemplateDefinitionMigrationError.database("Could not count \(table).")
        }
        return Int(value)
    }

    func strings(_ sql: String) throws -> [String] {
        try rows(sql).compactMap { $0.first as? String }
    }

    func execute(_ sql: String, bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        guard let handle,
              sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func rows(_ sql: String, bindings: [Binding] = []) throws -> [[Any?]] {
        var statement: OpaquePointer?
        guard let handle,
              sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var output: [[Any?]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW else { throw databaseError() }
            output.append((0..<sqlite3_column_count(statement)).map { index -> Any? in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return Int64(sqlite3_column_int64(statement, index))
                case SQLITE_TEXT:
                    return sqlite3_column_text(statement, index).map { String(cString: $0) }
                case SQLITE_BLOB:
                    guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
                    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
                default: return nil
                }
            })
        }
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch binding {
            case let .text(value):
                code = sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let .blob(value):
                code = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
            guard code == SQLITE_OK else { throw databaseError() }
        }
    }

    private func databaseError() -> TemplateDefinitionMigrationError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed."
        return .database(message)
    }
}
