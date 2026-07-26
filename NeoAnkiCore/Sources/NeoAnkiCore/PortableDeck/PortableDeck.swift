import CryptoKit
import Foundation
import SQLite3

public struct PortableDeckLimits: Sendable, Equatable {
    public var maximumFileBytes: Int64
    public var maximumDecks: Int
    public var maximumItemTypes: Int
    public var maximumItems: Int
    public var maximumFieldsPerType: Int
    public var maximumTemplatesPerType: Int
    public var maximumTagsPerItem: Int
    public var maximumMediaAssets: Int
    public var maximumTotalMediaBytes: Int64

    public init(
        maximumFileBytes: Int64 = 512_000_000,
        maximumDecks: Int = 1_000,
        maximumItemTypes: Int = 256,
        maximumItems: Int = 100_000,
        maximumFieldsPerType: Int = 256,
        maximumTemplatesPerType: Int = 256,
        maximumTagsPerItem: Int = 256,
        maximumMediaAssets: Int = 10_000,
        maximumTotalMediaBytes: Int64 = 500_000_000
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumDecks = maximumDecks
        self.maximumItemTypes = maximumItemTypes
        self.maximumItems = maximumItems
        self.maximumFieldsPerType = maximumFieldsPerType
        self.maximumTemplatesPerType = maximumTemplatesPerType
        self.maximumTagsPerItem = maximumTagsPerItem
        self.maximumMediaAssets = maximumMediaAssets
        self.maximumTotalMediaBytes = maximumTotalMediaBytes
    }

    public static let `default` = PortableDeckLimits()
}

public enum PortableDeckError: Error, Sendable, Equatable, LocalizedError {
    case invalidPackage(String)
    case unsupportedVersion(Int)
    case limitExceeded(String)
    case typeConflict(origin: String, existingDigest: String, importedDigest: String)
    case mediaUnavailable
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPackage(message): message
        case let .unsupportedVersion(version): "Portable deck version \(version) is not supported."
        case let .limitExceeded(message): message
        case let .typeConflict(origin, existing, imported):
            "Item type origin \(origin) conflicts (existing \(existing), imported \(imported))."
        case .mediaUnavailable: "Media storage is unavailable."
        case let .ioFailure(message): message
        }
    }
}

public struct PortableDeckImportResult: Sendable, Equatable {
    public let deckIDs: [UUID]
    public let itemCount: Int
    public let createdItemTypeCount: Int
    public let reusedItemTypeCount: Int

    public init(
        deckIDs: [UUID],
        itemCount: Int,
        createdItemTypeCount: Int,
        reusedItemTypeCount: Int
    ) {
        self.deckIDs = deckIDs
        self.itemCount = itemCount
        self.createdItemTypeCount = createdItemTypeCount
        self.reusedItemTypeCount = reusedItemTypeCount
    }
}

public enum PortableDeckTypeConflictResolution: Sendable, Equatable {
    /// Preserve destination schemas and report the conflict without importing.
    case reject
    /// Reuse a local type with the imported canonical digest, regardless of origin.
    case useMatchingSchema
    /// Keep both schema revisions by creating a new local item type.
    case importAsDistinctRevision
}

/// Isolates type identity policy from package I/O. Applications can provide a
/// resolver backed by durable origin/digest mappings without changing v1 I/O.
public protocol PortableDeckTypeResolver: Sendable {
    func origin(for itemType: ItemType) throws -> String
    func digest(for itemType: ItemType) throws -> String
}

public struct DefaultPortableDeckTypeResolver: PortableDeckTypeResolver {
    public init() {}

    public func origin(for itemType: ItemType) -> String {
        itemType.id.uuidString.lowercased()
    }

    public func digest(for itemType: ItemType) throws -> String {
        try itemType.portableSchemaDigest()
    }
}

struct PortableDeckPersistedItem: Sendable {
    let item: Item
    let createdAt: Date
    let updatedAt: Date
}

struct PortableDeckTypeRecord: Sendable {
    let itemType: ItemType
    let originLibraryID: UUID
    let originTypeID: UUID
    let digest: String
}

struct PortableDeckMediaRecord: Sendable {
    let descriptor: MediaAssetDescriptor
    /// A validated regular file. Package reads stage SQLite BLOBs here in
    /// bounded chunks; exports point directly at content-addressed media.
    let fileURL: URL
}

struct PortableDeckPackage: Sendable {
    let sourceLibraryID: UUID
    let rootDeckID: UUID
    let decks: [Deck]
    let types: [PortableDeckTypeRecord]
    let items: [PortableDeckPersistedItem]
    let media: [PortableDeckMediaRecord]
}

struct PortableDeckImportPlan: Sendable {
    let itemTypes: [ItemType]
    let decks: [Deck]
    let items: [PortableDeckPersistedItem]
    let mappings: [PortableDeckTypeMapping]
}

struct PortableDeckLibrarySnapshot: Sendable {
    let libraryID: UUID
    let decks: [Deck]
    let items: [PersistedItem]
    let itemTypes: [ItemType]
    let mappings: [PortableDeckTypeMapping]
}

struct PortableDeckTypeMapping: Sendable {
    let originLibraryID: UUID
    let originTypeID: UUID
    let digest: String
    let localTypeID: UUID
}

public enum PortableDeck {
    public static let fileExtension = "neodeck"
    public static let applicationID: Int32 = 0x4E44454B // "NDEK"
    public static let version = 1

    public static func export(
        deckID: UUID,
        from store: ItemStore,
        to destination: URL,
        limits: PortableDeckLimits = .default,
        resolver: any PortableDeckTypeResolver = DefaultPortableDeckTypeResolver()
    ) async throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == fileExtension else {
            throw PortableDeckError.ioFailure("Export destination must be a .neodeck file URL.")
        }
        let snapshot = try await store.portableDeckSnapshot(
            rootDeckID: deckID,
            limits: limits,
            resolver: resolver
        )
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).neodeck.tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            let database = try PortableDeckDatabase.create(at: temporary)
            try database.write(snapshot)
            try database.close()
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= limits.maximumFileBytes else {
                throw PortableDeckError.limitExceeded("Portable deck exceeds the file size limit.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch let error as PortableDeckError {
            throw error
        } catch {
            throw PortableDeckError.ioFailure("Could not export portable deck: \(error.localizedDescription)")
        }
    }

    public static func importDeck(
        from source: URL,
        into store: ItemStore,
        limits: PortableDeckLimits = .default,
        resolver: any PortableDeckTypeResolver = DefaultPortableDeckTypeResolver(),
        conflictResolution: PortableDeckTypeConflictResolution = .reject,
        now: Date = .now
    ) async throws -> PortableDeckImportResult {
        guard source.pathExtension.lowercased() == fileExtension else {
            throw PortableDeckError.invalidPackage("Portable deck must use the .neodeck extension.")
        }
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-portable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let package = try PortableDeckDatabase.read(
            at: source,
            limits: limits,
            stagingDirectory: stagingDirectory
        )
        return try await store.importPortableDeck(
            package,
            limits: limits,
            resolver: resolver,
            conflictResolution: conflictResolution,
            now: now
        )
    }
}

private final class PortableDeckDatabase {
    private var handle: OpaquePointer?
    private var writeStatementCache: [String: OpaquePointer] = [:]
    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { if let handle { sqlite3_close(handle) } }

    static func create(at url: URL) throws -> PortableDeckDatabase {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(
            url.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE | SQLITE_OPEN_READWRITE,
            nil
        )
        guard code == SQLITE_OK, let handle else {
            throw PortableDeckError.ioFailure("Could not create portable deck.")
        }
        let database = PortableDeckDatabase(handle: handle)
        try database.execute("PRAGMA foreign_keys = ON;")
        try database.execute("PRAGMA journal_mode = DELETE;")
        try database.execute("PRAGMA application_id = \(PortableDeck.applicationID);")
        try database.execute("PRAGMA user_version = \(PortableDeck.version);")
        for statement in schema {
            try database.execute(statement)
        }
        return database
    }

    static func read(
        at url: URL,
        limits: PortableDeckLimits,
        stagingDirectory: URL
    ) throws -> PortableDeckPackage {
        guard url.isFileURL else {
            throw PortableDeckError.invalidPackage("Portable deck must be a local file.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PortableDeckError.invalidPackage("Portable deck must be a regular file.")
        }
        guard Int64(values.fileSize ?? 0) <= limits.maximumFileBytes else {
            throw PortableDeckError.limitExceeded("Portable deck exceeds the file size limit.")
        }

        var handle: OpaquePointer?
        let code = sqlite3_open_v2(
            url.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard code == SQLITE_OK, let handle else {
            throw PortableDeckError.invalidPackage("Could not open portable deck.")
        }
        let database = PortableDeckDatabase(handle: handle)
        database.configureImportLimits(limits)
        try database.execute("PRAGMA query_only = ON;")
        try database.execute("PRAGMA trusted_schema = OFF;")
        try database.execute("PRAGMA foreign_keys = ON;")
        try database.validateHeaderAndIntegrity()
        return try database.readPackage(limits: limits, stagingDirectory: stagingDirectory)
    }

    func close() throws {
        guard let handle else { return }
        guard sqlite3_close(handle) == SQLITE_OK else {
            throw PortableDeckError.ioFailure("Could not close portable deck.")
        }
        self.handle = nil
    }

    func write(_ package: PortableDeckPackage) throws {
        defer {
            for statement in writeStatementCache.values { sqlite3_finalize(statement) }
            writeStatementCache.removeAll()
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            let typesByID = Dictionary(uniqueKeysWithValues: package.types.map {
                ($0.itemType.id, $0.itemType)
            })
            try execute(
                """
                INSERT INTO manifest(singleton, format_name, format_version, created_at, exporter,
                    source_library_id, root_deck_id, content_only)
                VALUES (1, 'neoanki-portable-deck', 1, ?, 'NeoAnki', ?, ?, 1);
                """,
                [
                    .text(Self.timestamp(.now)),
                    .text(package.sourceLibraryID.uuidString.lowercased()),
                    .null,
                ]
            )
            for deck in package.decks {
                let siblings = package.decks.filter { $0.parentID == deck.parentID }
                let index = siblings.firstIndex(where: { $0.id == deck.id }) ?? 0
                try execute(
                    "INSERT INTO decks(id, name, parent_id, ordinal) VALUES (?, ?, ?, ?);",
                    [
                        .text(deck.id.uuidString.lowercased()), .text(deck.name),
                        deck.parentID.map { .text($0.uuidString.lowercased()) } ?? .null,
                        .integer(Int64(index)),
                    ]
                )
            }
            try execute(
                "UPDATE manifest SET root_deck_id = ? WHERE singleton = 1;",
                [.text(package.rootDeckID.uuidString.lowercased())]
            )
            for record in package.types {
                try execute(
                    """
                    INSERT INTO item_types(id, name, origin_library_id, origin_type_id, schema_digest)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    [
                        .text(record.itemType.id.uuidString.lowercased()), .text(record.itemType.name),
                        .text(record.originLibraryID.uuidString.lowercased()),
                        .text(record.originTypeID.uuidString.lowercased()),
                        .blob(Data(hex: record.digest)),
                    ]
                )
                for (index, field) in record.itemType.fields.enumerated() {
                    try execute(
                        """
                        INSERT INTO fields(id, item_type_id, ordinal, name, kind, is_required)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """,
                        [
                            .text(field.id.uuidString.lowercased()),
                            .text(record.itemType.id.uuidString.lowercased()),
                            .integer(Int64(index)), .text(field.name), .text(field.type.rawValue),
                            .integer(field.isRequired ? 1 : 0),
                        ]
                    )
                }
                for (index, template) in record.itemType.templates.enumerated() {
                    let ordinals = Dictionary(uniqueKeysWithValues:
                        record.itemType.fields.enumerated().map { ($0.element.id, $0.offset) }
                    )
                    try execute(
                        """
                        INSERT INTO templates(id, item_type_id, ordinal, name, prompt_json,
                            answer_json, interaction, skill_json, generate_when_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        [
                            .text(template.id.uuidString.lowercased()),
                            .text(record.itemType.id.uuidString.lowercased()),
                            .integer(Int64(index)), .text(template.name),
                            .text(try PortableJSON.encodeSide(template.prompt, ordinals: ordinals)),
                            .text(try PortableJSON.encodeSide(template.answer, ordinals: ordinals)),
                            .text(template.interaction.rawValue),
                            .text(try PortableJSON.encodeSkill(template.skill)),
                            template.generateWhen.map {
                                .text(try PortableJSON.encodeCondition($0, ordinals: ordinals))
                            } ?? .null,
                        ]
                    )
                }
            }
            for record in package.items {
                let itemID = record.item.id.uuidString.lowercased()
                try execute(
                    """
                    INSERT INTO items(id, item_type_id, deck_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    [
                        .text(itemID), .text(record.item.itemTypeID.uuidString.lowercased()),
                        record.item.deckID.map { .text($0.uuidString.lowercased()) } ?? .null,
                        .text(Self.timestamp(record.createdAt)),
                        .text(Self.timestamp(record.updatedAt)),
                    ]
                )
                guard let itemType = typesByID[record.item.itemTypeID] else {
                    throw PortableDeckError.invalidPackage("An exported item type is missing.")
                }
                let valuesByField = Dictionary(
                    grouping: record.item.fields,
                    by: \.fieldID
                )
                guard valuesByField.values.allSatisfy({ $0.count == 1 }),
                      Set(valuesByField.keys).isSubset(of: Set(itemType.fields.map(\.id)))
                else {
                    throw PortableDeckError.invalidPackage("An exported item has invalid fields.")
                }
                for (ordinal, definition) in itemType.fields.enumerated() {
                    let value = valuesByField[definition.id]?.first?.value ?? .empty
                    try execute(
                        """
                        INSERT INTO item_fields(item_id, item_type_id, field_ordinal, value_json)
                        VALUES (?, ?, ?, ?);
                        """,
                        [
                            .text(itemID), .text(record.item.itemTypeID.uuidString.lowercased()),
                            .integer(Int64(ordinal)),
                            .text(try PortableJSON.encodeContent(value)),
                        ]
                    )
                }
                for (index, tag) in record.item.tags.enumerated() {
                    try execute(
                        "INSERT INTO item_tags(item_id, ordinal, tag) VALUES (?, ?, ?);",
                        [.text(itemID), .integer(Int64(index)), .text(tag)]
                    )
                }
            }
            for record in package.media {
                let mimeType = Self.mimeType(record.descriptor.fileExtension)
                guard mimeType != "application/octet-stream" else {
                    throw PortableDeckError.invalidPackage(
                        "A media format is not supported by portable deck version 1."
                    )
                }
                try execute(
                    """
                    INSERT INTO media_assets(digest, kind, mime_type, file_extension, byte_size, data)
                    VALUES (?, ?, ?, ?, ?, zeroblob(?));
                    """,
                    [
                        .blob(Data(hex: record.descriptor.hash)), .text(record.descriptor.kind.rawValue),
                        .text(mimeType),
                        .text(record.descriptor.fileExtension),
                        .integer(Int64(record.descriptor.byteSize)),
                        .integer(Int64(record.descriptor.byteSize)),
                    ]
                )
                try writeMediaBlob(record)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func validateHeaderAndIntegrity() throws {
        let appID = try scalarInteger("PRAGMA application_id;")
        guard appID == Int64(PortableDeck.applicationID) else {
            throw PortableDeckError.invalidPackage("File is not a NeoAnki portable deck.")
        }
        let version = Int(try scalarInteger("PRAGMA user_version;"))
        guard version == PortableDeck.version else {
            throw PortableDeckError.unsupportedVersion(version)
        }
        let rows = try query("PRAGMA quick_check(1);")
        guard rows.count == 1, rows[0].text(0) == "ok" else {
            throw PortableDeckError.invalidPackage("SQLite integrity check failed.")
        }
        let required = Set([
            "manifest", "decks", "item_types", "fields", "templates",
            "items", "item_fields", "item_tags", "media_assets",
        ])
        let actual = Set(try query(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
        ).compactMap { $0.text(0) })
        guard required == actual else {
            throw PortableDeckError.invalidPackage("Portable deck schema is incomplete.")
        }
        let executableObjects = try scalarInteger(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type IN ('view','trigger') OR sql LIKE '%VIRTUAL TABLE%';"
        )
        guard executableObjects == 0 else {
            throw PortableDeckError.invalidPackage("Portable deck contains unsupported schema objects.")
        }
        guard try query("PRAGMA foreign_key_check;").isEmpty else {
            throw PortableDeckError.invalidPackage("Portable deck foreign keys are invalid.")
        }
        try validateExactColumns()
    }

    private func configureImportLimits(_ limits: PortableDeckLimits) {
        guard let handle else { return }
        let largestMedia = max(
            MediaValidation.maxBytes(for: .audio),
            MediaValidation.maxBytes(for: .image),
            MediaValidation.maxBytes(for: .gif),
            MediaValidation.maxBytes(for: .video)
        )
        _ = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(min(Int(Int32.max), largestMedia + 1024)))
        _ = sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 100_000)
        _ = sqlite3_limit(handle, SQLITE_LIMIT_COLUMN, 64)
        _ = sqlite3_limit(handle, SQLITE_LIMIT_EXPR_DEPTH, 100)
        _ = sqlite3_limit(handle, SQLITE_LIMIT_COMPOUND_SELECT, 16)
        _ = sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, 64)
        _ = sqlite3_limit(handle, SQLITE_LIMIT_ATTACHED, 0)
        _ = limits
    }

    private func validateExactColumns() throws {
        let expected: [String: [String]] = [
            "manifest": [
                "singleton", "format_name", "format_version", "created_at", "exporter",
                "source_library_id", "root_deck_id", "content_only",
            ],
            "decks": ["id", "parent_id", "ordinal", "name"],
            "item_types": ["id", "name", "origin_library_id", "origin_type_id", "schema_digest"],
            "fields": ["id", "item_type_id", "ordinal", "name", "kind", "is_required"],
            "templates": [
                "id", "item_type_id", "ordinal", "name", "prompt_json", "answer_json",
                "interaction", "skill_json", "generate_when_json",
            ],
            "items": ["id", "item_type_id", "deck_id", "created_at", "updated_at"],
            "item_fields": ["item_id", "item_type_id", "field_ordinal", "value_json"],
            "item_tags": ["item_id", "ordinal", "tag"],
            "media_assets": [
                "digest", "kind", "mime_type", "file_extension", "byte_size", "data",
            ],
        ]
        for (table, columns) in expected {
            // Table identifiers are compile-time constants above.
            let actual = try query("PRAGMA table_info(\(table));").compactMap { $0.text(1) }
            guard actual == columns else {
                throw PortableDeckError.invalidPackage(
                    "Portable deck table \(table) has unexpected columns."
                )
            }
        }
    }

    private func writeMediaBlob(_ record: PortableDeckMediaRecord) throws {
        guard let handle else { throw PortableDeckError.ioFailure("Portable deck is closed.") }
        let digest = Data(hex: record.descriptor.hash)
        guard let rowID = try query(
            "SELECT rowid FROM media_assets WHERE digest = ?;",
            [.blob(digest)]
        ).first?.integer(0) else {
            throw PortableDeckError.ioFailure("Could not locate exported media row.")
        }
        var blob: OpaquePointer?
        guard sqlite3_blob_open(handle, "main", "media_assets", "data", rowID, 1, &blob) == SQLITE_OK,
              let blob else { throw sqliteError() }
        defer { sqlite3_blob_close(blob) }

        let input = try FileHandle(forReadingFrom: record.fileURL)
        defer { try? input.close() }
        var hasher = SHA256()
        var prefix = Data()
        var offset: Int32 = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= Int(Int32.max),
                  Int64(offset) + Int64(chunk.count) <= Int64(record.descriptor.byteSize)
            else { throw PortableDeckError.invalidPackage("Stored media exceeds its descriptor.") }
            let code = chunk.withUnsafeBytes {
                sqlite3_blob_write(blob, $0.baseAddress, Int32(chunk.count), offset)
            }
            guard code == SQLITE_OK else { throw sqliteError() }
            if prefix.count < 64 { prefix.append(chunk.prefix(64 - prefix.count)) }
            hasher.update(data: chunk)
            offset += Int32(chunk.count)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard Int(offset) == record.descriptor.byteSize, hash == record.descriptor.hash,
              (try? MediaValidation.validatedExtension(
                  data: prefix,
                  kind: record.descriptor.kind,
                  fileExtension: record.descriptor.fileExtension
              )) == record.descriptor.fileExtension
        else {
            throw PortableDeckError.invalidPackage("Stored media failed content validation.")
        }
    }

    private func stageMediaBlob(
        rowID: Int64,
        to destination: URL,
        expectedHash: String,
        kind: MediaKind,
        fileExtension: String,
        byteSize: Int
    ) throws {
        guard let handle else { throw PortableDeckError.invalidPackage("Portable deck is closed.") }
        var blob: OpaquePointer?
        guard sqlite3_blob_open(handle, "main", "media_assets", "data", rowID, 0, &blob) == SQLITE_OK,
              let blob, sqlite3_blob_bytes(blob) == Int32(byteSize)
        else { throw PortableDeckError.invalidPackage("Media BLOB size is invalid.") }
        defer { sqlite3_blob_close(blob) }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw PortableDeckError.ioFailure("Could not stage package media.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var prefix = Data()
        var offset = 0
        while offset < byteSize {
            let count = min(64 * 1024, byteSize - offset)
            var chunk = Data(count: count)
            let code = chunk.withUnsafeMutableBytes {
                sqlite3_blob_read(blob, $0.baseAddress, Int32(count), Int32(offset))
            }
            guard code == SQLITE_OK else { throw sqliteError() }
            try output.write(contentsOf: chunk)
            if prefix.count < 64 { prefix.append(chunk.prefix(64 - prefix.count)) }
            hasher.update(data: chunk)
            offset += count
        }
        try output.synchronize()
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash,
              (try? MediaValidation.validatedExtension(
                  data: prefix,
                  kind: kind,
                  fileExtension: fileExtension
              )) == fileExtension
        else {
            throw PortableDeckError.invalidPackage("Media bytes do not match their metadata.")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value), timestamp(date) == value else { return nil }
        return date
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext {
        case "jpg": "image/jpeg"
        case "png": "image/png"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "wav": "audio/wav"
        case "ogg": "audio/ogg"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "webm": "video/webm"
        default: "application/octet-stream"
        }
    }

    private func readPackage(
        limits: PortableDeckLimits,
        stagingDirectory: URL
    ) throws -> PortableDeckPackage {
        try enforceCount(table: "decks", maximum: limits.maximumDecks)
        try enforceCount(table: "item_types", maximum: limits.maximumItemTypes)
        try enforceCount(table: "items", maximum: limits.maximumItems)
        try enforceCount(table: "media_assets", maximum: limits.maximumMediaAssets)

        let manifestRows = try query(
            """
            SELECT singleton, format_name, format_version, source_library_id, root_deck_id,
                content_only
            FROM manifest;
            """
        )
        guard manifestRows.count == 1,
              manifestRows[0].integer(0) == 1,
              manifestRows[0].text(1) == "neoanki-portable-deck",
              manifestRows[0].integer(2) == Int64(PortableDeck.version),
              let sourceLibraryID = manifestRows[0].uuid(3),
              let rootDeckID = manifestRows[0].uuid(4),
              manifestRows[0].integer(5) == 1 else {
            throw PortableDeckError.invalidPackage("Root deck identifier is missing.")
        }

        let deckRows = try query(
            "SELECT id, name, parent_id, ordinal FROM decks ORDER BY parent_id, ordinal;"
        )
        let deckGroups = Dictionary(grouping: deckRows) { $0.text(2) ?? "" }
        guard deckGroups.values.allSatisfy({ rows in
            rows.enumerated().allSatisfy { index, row in row.integer(3) == Int64(index) }
        }) else {
            throw PortableDeckError.invalidPackage("Deck ordinals are invalid.")
        }
        let decks = try deckRows.map { row in
            guard let id = row.uuid(0), let name = row.text(1) else {
                throw PortableDeckError.invalidPackage("Deck row is invalid.")
            }
            guard name.utf8.count <= 1_024,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PortableDeckError.invalidPackage("Deck name is invalid.") }
            return Deck(id: id, name: name, parentID: row.uuid(2))
        }
        guard decks.contains(where: { $0.id == rootDeckID }) else {
            throw PortableDeckError.invalidPackage("Root deck does not exist.")
        }
        try validateDeckTree(decks, root: rootDeckID)

        let allFieldRows = try query(
            """
            SELECT item_type_id, id, ordinal, name, kind, is_required
            FROM fields ORDER BY item_type_id, ordinal;
            """
        )
        let fieldsByType = Dictionary(grouping: allFieldRows) { $0.text(0) ?? "" }
        let allTemplateRows = try query(
            """
            SELECT item_type_id, id, ordinal, name, prompt_json, answer_json, interaction,
                skill_json, generate_when_json
            FROM templates ORDER BY item_type_id, ordinal;
            """
        )
        let templatesByType = Dictionary(grouping: allTemplateRows) { $0.text(0) ?? "" }
        var types: [PortableDeckTypeRecord] = []
        for row in try query(
            "SELECT id, origin_library_id, origin_type_id, schema_digest, name FROM item_types ORDER BY id;"
        ) {
            let digest = row.blob(3).hex
            guard let id = row.uuid(0), let originLibraryID = row.uuid(1),
                  let originTypeID = row.uuid(2), isDigest(digest), let name = row.text(4)
            else { throw PortableDeckError.invalidPackage("Item type row is invalid.") }
            let typeKey = id.uuidString.lowercased()
            let fields = fieldsByType[typeKey] ?? []
            guard fields.count <= limits.maximumFieldsPerType else {
                throw PortableDeckError.limitExceeded("An item type has too many fields.")
            }
            let templates = templatesByType[typeKey] ?? []
            guard templates.count <= limits.maximumTemplatesPerType else {
                throw PortableDeckError.limitExceeded("An item type has too many templates.")
            }
            let decodedFields = try fields.enumerated().map { index, fieldRow -> FieldDef in
                guard let fieldID = fieldRow.uuid(1), let ordinal = fieldRow.integer(2),
                      ordinal == Int64(index), Int(ordinal) < limits.maximumFieldsPerType,
                      let fieldName = fieldRow.text(3),
                      let kindText = fieldRow.text(4), let kind = FieldType(rawValue: kindText),
                      let required = fieldRow.integer(5), required == 0 || required == 1
                else { throw PortableDeckError.invalidPackage("Field row is invalid.") }
                return FieldDef(id: fieldID, name: fieldName, type: kind, isRequired: required == 1)
            }
            let decodedTemplates = try templates.enumerated().map { index, templateRow -> Template in
                guard let templateID = templateRow.uuid(1), let ordinal = templateRow.integer(2),
                      ordinal == Int64(index), Int(ordinal) < limits.maximumTemplatesPerType,
                      let templateName = templateRow.text(3),
                      let prompt = templateRow.text(4), let answer = templateRow.text(5),
                      let interactionText = templateRow.text(6),
                      let interaction = Interaction(rawValue: interactionText),
                      let skill = templateRow.text(7)
                else { throw PortableDeckError.invalidPackage("Template row is invalid.") }
                let condition: SlotCondition? = try templateRow.text(8).map {
                    try PortableJSON.decodeCondition($0, fields: decodedFields)
                }
                return Template(
                    id: templateID, name: templateName,
                    prompt: try PortableJSON.decodeSide(prompt, fields: decodedFields),
                    answer: try PortableJSON.decodeSide(answer, fields: decodedFields),
                    interaction: interaction,
                    skill: try PortableJSON.decodeSkill(skill),
                    generateWhen: condition
                )
            }
            let type = ItemType(
                id: id,
                name: name,
                fields: decodedFields,
                templates: decodedTemplates
            )
            try ItemTypeValidation.validate(type)
            types.append(.init(
                itemType: type, originLibraryID: originLibraryID,
                originTypeID: originTypeID, digest: digest
            ))
        }

        let deckIDs = Set(decks.map(\.id))
        let typeIDs = Set(types.map(\.itemType.id))
        let allItemFieldRows = try query(
            """
            SELECT item_id, item_type_id, field_ordinal, value_json
            FROM item_fields ORDER BY item_id, field_ordinal;
            """
        )
        let fieldsByItem = Dictionary(grouping: allItemFieldRows) { $0.text(0) ?? "" }
        let allTagRows = try query(
            "SELECT item_id, ordinal, tag FROM item_tags ORDER BY item_id, ordinal;"
        )
        let tagsByItem = Dictionary(grouping: allTagRows) { $0.text(0) ?? "" }
        let itemTypesByID = Dictionary(uniqueKeysWithValues: types.map {
            ($0.itemType.id, $0.itemType)
        })
        var items: [PortableDeckPersistedItem] = []
        for row in try query(
            "SELECT id, item_type_id, deck_id, created_at, updated_at FROM items ORDER BY rowid;"
        ) {
            guard let id = row.uuid(0), let typeID = row.uuid(1), typeIDs.contains(typeID),
                  let deckID = row.uuid(2), deckIDs.contains(deckID),
                  let createdText = row.text(3), let created = Self.parseTimestamp(createdText),
                  let updatedText = row.text(4), let updated = Self.parseTimestamp(updatedText)
            else { throw PortableDeckError.invalidPackage("Item row is invalid.") }
            let itemKey = id.uuidString.lowercased()
            let fieldRows = fieldsByItem[itemKey] ?? []
            guard fieldRows.count <= limits.maximumFieldsPerType else {
                throw PortableDeckError.limitExceeded("An item has too many field values.")
            }
            guard let itemType = itemTypesByID[typeID],
                  fieldRows.count == itemType.fields.count
            else {
                throw PortableDeckError.invalidPackage("Item type is missing.")
            }
            let fields = try fieldRows.enumerated().map { index, fieldRow -> FieldValue in
                guard fieldRow.uuid(1) == typeID,
                      let ordinal = fieldRow.integer(2), ordinal >= 0,
                      ordinal == Int64(index),
                      Int(ordinal) < itemType.fields.count, let json = fieldRow.text(3) else {
                    throw PortableDeckError.invalidPackage("Item field identifier is invalid.")
                }
                return FieldValue(
                    fieldID: itemType.fields[Int(ordinal)].id,
                    value: try PortableJSON.decodeContent(json)
                )
            }
            let tagRows = tagsByItem[itemKey] ?? []
            guard tagRows.count <= limits.maximumTagsPerItem else {
                throw PortableDeckError.limitExceeded("An item has too many tags.")
            }
            let tags = try tagRows.enumerated().map { index, row in
                guard row.integer(1) == Int64(index),
                      let tag = row.text(2), tag.utf8.count <= 1_024,
                      !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw PortableDeckError.invalidPackage("An item tag is invalid.")
                }
                return tag
            }
            items.append(.init(
                item: Item(id: id, itemTypeID: typeID, fields: fields, tags: tags, deckID: deckID),
                createdAt: created,
                updatedAt: updated
            ))
        }

        var totalMediaBytes: Int64 = 0
        var media: [PortableDeckMediaRecord] = []
        for row in try query(
            """
            SELECT rowid, digest, kind, mime_type, file_extension, byte_size
            FROM media_assets ORDER BY digest;
            """
        ) {
            guard let rowID = row.integer(0) else {
                throw PortableDeckError.invalidPackage("Media row is invalid.")
            }
            let hash = row.blob(1).hex
            guard isDigest(hash), let kindText = row.text(2),
                  let kind = MediaKind(rawValue: kindText), let mime = row.text(3),
                  let ext = row.text(4), mime == Self.mimeType(ext),
                  let byteSize = row.integer(5), byteSize >= 0,
                  byteSize <= Int64(MediaValidation.maxBytes(for: kind))
            else { throw PortableDeckError.invalidPackage("Media metadata is invalid.") }
            let (sum, overflow) = totalMediaBytes.addingReportingOverflow(byteSize)
            guard !overflow, sum <= limits.maximumTotalMediaBytes else {
                throw PortableDeckError.limitExceeded("Portable deck contains too much media.")
            }
            totalMediaBytes = sum
            let fileURL = stagingDirectory.appendingPathComponent(
                "\(hash).\(ext)",
                isDirectory: false
            )
            try stageMediaBlob(
                rowID: rowID,
                to: fileURL,
                expectedHash: hash,
                kind: kind,
                fileExtension: ext,
                byteSize: Int(byteSize)
            )
            media.append(.init(
                descriptor: .init(
                    hash: hash, kind: kind, byteSize: Int(byteSize), fileExtension: ext
                ),
                fileURL: fileURL
            ))
        }
        try validateMediaReferences(items: items, media: media)
        return .init(
            sourceLibraryID: sourceLibraryID, rootDeckID: rootDeckID,
            decks: decks, types: types, items: items, media: media
        )
    }

    private func validateDeckTree(_ decks: [Deck], root: UUID) throws {
        let byID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        for deck in decks {
            if deck.id == root {
                guard deck.parentID == nil else {
                    throw PortableDeckError.invalidPackage("Root deck must not have a parent.")
                }
            } else {
                guard let parent = deck.parentID, byID[parent] != nil else {
                    throw PortableDeckError.invalidPackage("Deck hierarchy has an external parent.")
                }
            }
            var seen: Set<UUID> = []
            var cursor: UUID? = deck.id
            while let current = cursor {
                guard seen.insert(current).inserted else {
                    throw PortableDeckError.invalidPackage("Deck hierarchy contains a cycle.")
                }
                cursor = byID[current]?.parentID
            }
        }
    }

    private func validateMediaReferences(
        items: [PortableDeckPersistedItem],
        media: [PortableDeckMediaRecord]
    ) throws {
        let byHash = Dictionary(uniqueKeysWithValues: media.map { ($0.descriptor.hash, $0.descriptor) })
        for record in items {
            for field in record.item.fields {
                guard case let .media(ref) = field.value else { continue }
                guard let descriptor = byHash[ref.assetHash],
                      descriptor.kind == ref.kind,
                      descriptor.fileExtension == ref.fileExtension
                else {
                    throw PortableDeckError.invalidPackage("An item references missing media.")
                }
            }
        }
    }

    private func enforceCount(table: String, maximum: Int) throws {
        // Table names are compile-time constants from this file, never package input.
        let count = try scalarInteger("SELECT COUNT(*) FROM \(table);")
        guard count <= Int64(maximum) else {
            throw PortableDeckError.limitExceeded("Portable deck \(table) count exceeds its limit.")
        }
    }

    private func scalarInteger(_ sql: String) throws -> Int64 {
        guard let value = try query(sql).first?.integer(0) else {
            throw PortableDeckError.invalidPackage("Expected an integer database value.")
        }
        return value
    }

    private func execute(_ sql: String, _ bindings: [Value] = []) throws {
        let statement: OpaquePointer
        let cached = !writeStatementCache.isEmpty || sql == "BEGIN IMMEDIATE;"
        if cached, let existing = writeStatementCache[sql] {
            statement = existing
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(bindings, to: statement)
        } else {
            statement = try prepare(sql, bindings)
            if cached {
                writeStatementCache[sql] = statement
            }
        }
        defer { if !cached { sqlite3_finalize(statement) } }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw sqliteError() }
        }
    }

    private func query(_ sql: String, _ bindings: [Value] = []) throws -> [Row] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw sqliteError() }
            rows.append(Row(statement))
        }
    }

    private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        guard let handle else { throw PortableDeckError.ioFailure("Portable deck is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        do {
            try bind(bindings, to: statement)
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func bind(_ bindings: [Value], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch binding {
            case let .text(value):
                code = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let .blob(data):
                guard data.count <= Int(Int32.max) else {
                    throw PortableDeckError.limitExceeded("A SQLite value is too large.")
                }
                code = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
                }
            case let .integer(value): code = sqlite3_bind_int64(statement, index, value)
            case let .real(value): code = sqlite3_bind_double(statement, index, value)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else {
                throw PortableDeckError.invalidPackage("Could not bind SQLite value.")
            }
        }
    }

    private func sqliteError() -> PortableDeckError {
        let message = handle.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "SQLite failure."
        return .invalidPackage(message)
    }
}

private enum Value {
    case text(String)
    case blob(Data)
    case integer(Int64)
    case real(Double)
    case null
}

private struct Row {
    private let values: [Value]

    init(_ statement: OpaquePointer) {
        values = (0..<sqlite3_column_count(statement)).map { index in
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                .blob(Data(
                    bytes: sqlite3_column_blob(statement, index),
                    count: Int(sqlite3_column_bytes(statement, index))
                ))
            default: .null
            }
        }
    }

    func text(_ index: Int) -> String? {
        guard case let .text(value) = values[index] else { return nil }
        return value
    }

    func blob(_ index: Int) -> Data {
        guard case let .blob(value) = values[index] else { return Data() }
        return value
    }

    func integer(_ index: Int) -> Int64? {
        guard case let .integer(value) = values[index] else { return nil }
        return value
    }

    func double(_ index: Int) -> Double? {
        switch values[index] {
        case let .real(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }

    func uuid(_ index: Int) -> UUID? {
        guard let value = text(index), value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value,
              uuid != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        else { return nil }
        return uuid
    }
}

private func isDigest(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}

private enum PortableJSON {
    private static let maximumJSONBytes = 1_048_576
    private static let maximumTextBytes = 256 * 1_024
    private static let styleOrder: [Span.Style] = [
        .bold, .italic, .underline, .strikethrough, .highlight, .code,
    ]

    static func encodeSide(_ side: Side, ordinals: [UUID: Int]) throws -> String {
        try encode(side.slots.map { slot -> [String: Any] in
            let source: [String: Any]
            switch slot.source {
            case let .field(id):
                guard let ordinal = ordinals[id] else { throw invalid() }
                source = ["field": ordinal]
            case let .literal(value):
                try validateText(value)
                source = ["literal": value]
            }
            return [
                "source": source,
                "presentation": [
                    "reveal": slot.presentation.reveal.rawValue,
                    "media": slot.presentation.media.rawValue,
                ],
            ]
        })
    }

    static func decodeSide(_ json: String, fields: [FieldDef]) throws -> Side {
        guard let slots = try object(json) as? [Any], slots.count <= 512 else { throw invalid() }
        return Side(slots: try slots.map { value in
            let slot = try dictionary(value, keys: ["source", "presentation"])
            let sourceObject = try dictionary(required(slot["source"]))
            let source: SlotSource
            if Set(sourceObject.keys) == ["field"] {
                let ordinal = try integer(required(sourceObject["field"]))
                guard fields.indices.contains(ordinal) else { throw invalid() }
                source = .field(fields[ordinal].id)
            } else if Set(sourceObject.keys) == ["literal"],
                      let literal = sourceObject["literal"] as? String {
                try validateText(literal)
                source = .literal(literal)
            } else {
                throw invalid()
            }
            let presentation = try dictionary(
                required(slot["presentation"]),
                keys: ["reveal", "media"]
            )
            guard let revealText = presentation["reveal"] as? String,
                  let reveal = RevealMode(rawValue: revealText),
                  let mediaText = presentation["media"] as? String,
                  let media = MediaBehavior(rawValue: mediaText)
            else { throw invalid() }
            return Slot(source: source, presentation: Presentation(reveal: reveal, media: media))
        })
    }

    static func encodeSkill(_ skill: Skill) throws -> String {
        try encode([
            "input": skill.input.rawValue,
            "operation": skill.operation.rawValue,
            "output": skill.output.rawValue,
        ])
    }

    static func decodeSkill(_ json: String) throws -> Skill {
        let value = try dictionary(
            object(json),
            keys: ["input", "operation", "output"]
        )
        guard let inputText = value["input"] as? String, let input = Modality(rawValue: inputText),
              let outputText = value["output"] as? String, let output = Modality(rawValue: outputText),
              let operationText = value["operation"] as? String,
              let operation = Operation(rawValue: operationText)
        else { throw invalid() }
        return Skill(input: input, output: output, operation: operation)
    }

    static func encodeCondition(_ condition: SlotCondition, ordinals: [UUID: Int]) throws -> String {
        try encode(try conditionObject(condition, ordinals: ordinals))
    }

    static func decodeCondition(_ json: String, fields: [FieldDef]) throws -> SlotCondition {
        var nodes = 0
        return try decodeConditionObject(object(json), fields: fields, depth: 0, nodes: &nodes)
    }

    static func encodeContent(_ content: ContentValue) throws -> String {
        var value: [String: Any]
        switch content {
        case .empty:
            value = ["type": "empty"]
        case let .text(text, lang):
            try validateText(text)
            value = ["type": "text", "text": text]
            if let lang { value["lang"] = lang }
        case let .rich(spans):
            guard spans.count <= 4_096 else { throw invalid() }
            value = [
                "type": "rich",
                "spans": try spans.map { span -> [String: Any] in
                    try validateText(span.text)
                    return [
                        "text": span.text,
                        "styles": styleOrder.filter { span.styles.contains($0) }.map(\.rawValue),
                    ]
                },
            ]
        case let .number(number):
            guard number.isFinite else { throw invalid() }
            value = ["type": "number", "value": number]
        case let .cloze(text, blanks):
            try validateText(text)
            guard blanks.count <= 4_096 else { throw invalid() }
            value = [
                "type": "cloze",
                "text": text,
                "blanks": try blanks.map { blank -> [String: Any] in
                    guard blank.group > 0, blank.start >= 0, blank.length > 0 else { throw invalid() }
                    var object: [String: Any] = [
                        "group": blank.group, "start": blank.start, "length": blank.length,
                    ]
                    if let hint = blank.hint {
                        try validateText(hint)
                        object["hint"] = hint
                    }
                    return object
                },
            ]
        case let .media(ref):
            guard isDigest(ref.assetHash) else { throw invalid() }
            value = [
                "type": "media", "digest": ref.assetHash, "kind": ref.kind.rawValue,
                "extension": ref.fileExtension,
            ]
            if let duration = ref.durationMs {
                guard duration >= 0 else { throw invalid() }
                value["durationMs"] = duration
            }
            if let alt = ref.altText {
                try validateText(alt)
                value["altText"] = alt
            }
        }
        return try encode(value)
    }

    static func decodeContent(_ json: String) throws -> ContentValue {
        let value = try dictionary(object(json))
        guard let type = value["type"] as? String else { throw invalid() }
        switch type {
        case "empty":
            guard Set(value.keys) == ["type"] else { throw invalid() }
            return .empty
        case "text":
            guard Set(value.keys).isSubset(of: ["type", "text", "lang"]),
                  value.keys.contains("text"), let text = value["text"] as? String
            else { throw invalid() }
            try validateText(text)
            guard value["lang"] == nil || value["lang"] is String else { throw invalid() }
            return .text(text, lang: value["lang"] as? String)
        case "rich":
            guard Set(value.keys) == ["type", "spans"], let raw = value["spans"] as? [Any],
                  raw.count <= 4_096 else { throw invalid() }
            return .rich(try raw.map { rawSpan in
                let span = try dictionary(rawSpan, keys: ["text", "styles"])
                guard let text = span["text"] as? String, let rawStyles = span["styles"] as? [Any]
                else { throw invalid() }
                try validateText(text)
                let styles = try rawStyles.map { raw -> Span.Style in
                    guard let text = raw as? String, let style = Span.Style(rawValue: text) else {
                        throw invalid()
                    }
                    return style
                }
                let styleSet = Set(styles)
                let canonicalStyles = styleOrder.filter { styleSet.contains($0) }
                guard styleSet.count == styles.count, styles == canonicalStyles
                else { throw invalid() }
                return Span(text, styles: Set(styles))
            })
        case "number":
            guard Set(value.keys) == ["type", "value"],
                  let number = value["value"] as? NSNumber,
                  number.doubleValue.isFinite else { throw invalid() }
            return .number(number.doubleValue)
        case "cloze":
            guard Set(value.keys) == ["type", "text", "blanks"],
                  let text = value["text"] as? String, let raw = value["blanks"] as? [Any],
                  raw.count <= 4_096 else { throw invalid() }
            try validateText(text)
            return .cloze(text, blanks: try raw.map { rawBlank in
                let blank = try dictionary(rawBlank)
                guard Set(blank.keys).isSubset(of: ["group", "start", "length", "hint"]),
                      Set(blank.keys).isSuperset(of: ["group", "start", "length"])
                else { throw invalid() }
                let group = try integer(required(blank["group"]))
                let start = try integer(required(blank["start"]))
                let length = try integer(required(blank["length"]))
                guard group > 0, start >= 0, length > 0,
                      blank["hint"] == nil || blank["hint"] is String
                else { throw invalid() }
                if let hint = blank["hint"] as? String { try validateText(hint) }
                return ClozeSpan(group: group, start: start, length: length, hint: blank["hint"] as? String)
            })
        case "media":
            guard Set(value.keys).isSubset(of: [
                "type", "digest", "kind", "extension", "durationMs", "altText",
            ]),
            Set(value.keys).isSuperset(of: ["type", "digest", "kind", "extension"]),
            let digest = value["digest"] as? String, isDigest(digest),
            let kindText = value["kind"] as? String, let kind = MediaKind(rawValue: kindText),
            let ext = value["extension"] as? String,
            MediaValidation.allowedExtensions(for: kind).contains(ext)
            else { throw invalid() }
            let duration = try value["durationMs"].map(integer)
            guard duration == nil || duration! >= 0,
                  value["altText"] == nil || value["altText"] is String
            else { throw invalid() }
            if let alt = value["altText"] as? String { try validateText(alt) }
            return .media(MediaRef(
                kind: kind, assetHash: digest, fileExtension: ext,
                durationMs: duration, altText: value["altText"] as? String
            ))
        default:
            throw invalid()
        }
    }

    private static func conditionObject(
        _ condition: SlotCondition,
        ordinals: [UUID: Int]
    ) throws -> [String: Any] {
        switch condition {
        case let .fieldNotEmpty(id):
            guard let ordinal = ordinals[id] else { throw invalid() }
            return ["fieldNotEmpty": ordinal]
        case let .fieldEmpty(id):
            guard let ordinal = ordinals[id] else { throw invalid() }
            return ["fieldEmpty": ordinal]
        case let .all(children):
            guard !children.isEmpty else { throw invalid() }
            return ["all": try children.map { try conditionObject($0, ordinals: ordinals) }]
        case let .any(children):
            guard !children.isEmpty else { throw invalid() }
            return ["any": try children.map { try conditionObject($0, ordinals: ordinals) }]
        }
    }

    private static func decodeConditionObject(
        _ raw: Any,
        fields: [FieldDef],
        depth: Int,
        nodes: inout Int
    ) throws -> SlotCondition {
        nodes += 1
        guard depth <= 64, nodes <= 1_024 else { throw invalid() }
        let value = try dictionary(raw)
        guard value.count == 1, let key = value.keys.first else { throw invalid() }
        if key == "fieldNotEmpty" || key == "fieldEmpty" {
            let ordinal = try integer(required(value[key]))
            guard fields.indices.contains(ordinal) else { throw invalid() }
            return key == "fieldNotEmpty"
                ? .fieldNotEmpty(fields[ordinal].id)
                : .fieldEmpty(fields[ordinal].id)
        }
        guard (key == "all" || key == "any"), let children = value[key] as? [Any],
              !children.isEmpty else { throw invalid() }
        let decoded = try children.map {
            try decodeConditionObject($0, fields: fields, depth: depth + 1, nodes: &nodes)
        }
        return key == "all" ? .all(decoded) : .any(decoded)
    }

    private static func object(_ json: String) throws -> Any {
        let data = Data(json.utf8)
        guard data.count <= maximumJSONBytes else {
            throw PortableDeckError.limitExceeded("A portable deck JSON value is too large.")
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw invalid()
        }
    }

    private static func encode(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else { throw invalid() }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= maximumJSONBytes else {
            throw PortableDeckError.limitExceeded("A portable deck JSON value is too large.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dictionary(_ raw: Any, keys: Set<String>? = nil) throws -> [String: Any] {
        guard let value = raw as? [String: Any],
              keys == nil || Set(value.keys) == keys!
        else {
            throw invalid()
        }
        return value
    }

    private static func integer(_ raw: Any) throws -> Int {
        guard let number = raw as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max)
        else { throw invalid() }
        return number.intValue
    }

    private static func required(_ value: Any?) throws -> Any {
        guard let value else { throw invalid() }
        return value
    }

    private static func validateText(_ text: String) throws {
        guard text.utf8.count <= maximumTextBytes else {
            throw PortableDeckError.limitExceeded("Portable deck text is too large.")
        }
    }

    private static func invalid() -> PortableDeckError {
        .invalidPackage("A portable deck JSON value is malformed.")
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private let schema = [
    """
    CREATE TABLE manifest (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
        format_name TEXT NOT NULL CHECK (format_name = 'neoanki-portable-deck'),
        format_version INTEGER NOT NULL CHECK (format_version = 1),
        created_at TEXT NOT NULL, exporter TEXT NOT NULL,
        source_library_id TEXT NOT NULL, root_deck_id TEXT REFERENCES decks(id) ON DELETE RESTRICT,
        content_only INTEGER NOT NULL CHECK (content_only = 1),
        CHECK (length(source_library_id) = 36),
        CHECK (root_deck_id IS NULL OR length(root_deck_id) = 36)
    );
    """,
    """
    CREATE TABLE decks(
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
        parent_id TEXT REFERENCES decks(id) ON DELETE RESTRICT,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0), name TEXT NOT NULL
    );
    """,
    """
    CREATE TABLE item_types(
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36), name TEXT NOT NULL,
        origin_library_id TEXT NOT NULL CHECK(length(origin_library_id) = 36),
        origin_type_id TEXT NOT NULL CHECK(length(origin_type_id) = 36),
        schema_digest BLOB NOT NULL CHECK(length(schema_digest) = 32),
        UNIQUE(origin_library_id, origin_type_id)
    );
    """,
    """
    CREATE TABLE fields(
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
        item_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0), name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('text','richText','audio','image','gif','video','number','cloze')),
        is_required INTEGER NOT NULL CHECK(is_required IN (0,1)),
        UNIQUE(item_type_id, ordinal), UNIQUE(item_type_id, id)
    );
    """,
    """
    CREATE TABLE templates(
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
        item_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0), name TEXT NOT NULL,
        prompt_json TEXT NOT NULL, answer_json TEXT NOT NULL,
        interaction TEXT NOT NULL CHECK(interaction IN ('reveal','type','choose','record','cloze','arrange')),
        skill_json TEXT NOT NULL, generate_when_json TEXT,
        UNIQUE(item_type_id, ordinal), UNIQUE(item_type_id, id)
    );
    """,
    """
    CREATE TABLE items(
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
        item_type_id TEXT NOT NULL REFERENCES item_types(id) ON DELETE RESTRICT,
        deck_id TEXT REFERENCES decks(id) ON DELETE RESTRICT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE(id, item_type_id)
    );
    """,
    """
    CREATE TABLE item_fields(
        item_id TEXT NOT NULL, item_type_id TEXT NOT NULL,
        field_ordinal INTEGER NOT NULL CHECK(field_ordinal >= 0), value_json TEXT NOT NULL,
        PRIMARY KEY(item_id, field_ordinal),
        FOREIGN KEY(item_id, item_type_id) REFERENCES items(id, item_type_id) ON DELETE CASCADE,
        FOREIGN KEY(item_type_id, field_ordinal) REFERENCES fields(item_type_id, ordinal) ON DELETE RESTRICT
    );
    """,
    """
    CREATE TABLE item_tags(
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0), tag TEXT NOT NULL,
        PRIMARY KEY(item_id, ordinal)
    );
    """,
    """
    CREATE TABLE media_assets(
        digest BLOB PRIMARY KEY NOT NULL CHECK(length(digest) = 32),
        kind TEXT NOT NULL CHECK(kind IN ('audio','image','gif','video')),
        mime_type TEXT NOT NULL, file_extension TEXT NOT NULL,
        byte_size INTEGER NOT NULL CHECK(byte_size >= 0), data BLOB NOT NULL,
        CHECK(length(data) = byte_size)
    );
    """,
    "CREATE UNIQUE INDEX idx_decks_parent_ordinal ON decks(COALESCE(parent_id, ''), ordinal);",
    "CREATE INDEX idx_item_types_schema_digest ON item_types(schema_digest);",
    "CREATE INDEX idx_fields_item_type_ordinal ON fields(item_type_id, ordinal);",
    "CREATE INDEX idx_templates_item_type_ordinal ON templates(item_type_id, ordinal);",
    "CREATE INDEX idx_items_item_type ON items(item_type_id);",
    "CREATE INDEX idx_items_deck ON items(deck_id);",
    "CREATE INDEX idx_item_fields_item_type ON item_fields(item_type_id, field_ordinal);",
    "CREATE INDEX idx_item_tags_tag ON item_tags(tag);",
]

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
