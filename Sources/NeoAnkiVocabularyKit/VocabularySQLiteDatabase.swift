import Foundation
import SQLite3

final class VocabularySQLiteDatabase: @unchecked Sendable {
    static let applicationID: Int32 = 0x4E564F43 // NVOC
    static let schemaVersion = 1

    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static let entriesTableSQL = """
    CREATE TABLE entries(
        id TEXT PRIMARY KEY NOT NULL,
        language TEXT NOT NULL,
        canonical TEXT NOT NULL,
        search_key TEXT NOT NULL,
        frequency REAL,
        payload BLOB NOT NULL
    ) WITHOUT ROWID
    """
    private static let formsTableSQL = """
    CREATE TABLE entry_forms(
        entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        language TEXT,
        value TEXT NOT NULL,
        search_key TEXT NOT NULL,
        PRIMARY KEY(entry_id, ordinal)
    ) WITHOUT ROWID
    """
    private static let entriesIndexSQL =
        "CREATE INDEX entries_search_key_idx ON entries(search_key, language, canonical)"
    private static let formsIndexSQL =
        "CREATE INDEX entry_forms_search_key_idx ON entry_forms(search_key, language, entry_id)"

    init(url: URL, readOnly: Bool) throws {
        var database: OpaquePointer?
        let flags: Int32 = readOnly
            // Symlinks and the content digest are validated immediately before this open.
            // Apple's SQLite build rejects OPEN_NOFOLLOW even for an existing regular file.
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            // The compiler creates this file inside a fresh private staging directory. Apple's
            // SQLite rejects NOFOLLOW for a not-yet-created file, so it is intentionally omitted.
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let filename = readOnly
            ? url.absoluteString + "?mode=ro&immutable=1"
            : url.path(percentEncoded: false)
        let code = sqlite3_open_v2(filename, &database, flags, nil)
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw VocabularyPackError.databaseFailure(String(cString: sqlite3_errstr(code)))
        }
        handle = database
        _ = sqlite3_extended_result_codes(database, 1)
        _ = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 16_000_000)
        _ = sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 100_000)
        _ = sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 64)
        _ = sqlite3_limit(database, SQLITE_LIMIT_EXPR_DEPTH, 100)
        _ = sqlite3_limit(database, SQLITE_LIMIT_COMPOUND_SELECT, 8)
        _ = sqlite3_limit(database, SQLITE_LIMIT_VARIABLE_NUMBER, 16)
        _ = sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, 0)
        do {
            try execute("PRAGMA trusted_schema = OFF;")
            try execute("PRAGMA foreign_keys = ON;")
            if readOnly { try execute("PRAGMA query_only = ON;") }
        } catch {
            sqlite3_close(database)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func close() throws {
        guard let handle else { return }
        let code = sqlite3_close(handle)
        guard code == SQLITE_OK else { throw sqliteError(code) }
        self.handle = nil
    }

    func createSchema() throws {
        try execute("""
        PRAGMA journal_mode = DELETE;
        PRAGMA synchronous = FULL;
        PRAGMA application_id = \(Self.applicationID);
        PRAGMA user_version = \(Self.schemaVersion);
        \(Self.entriesTableSQL);
        \(Self.formsTableSQL);
        \(Self.entriesIndexSQL);
        \(Self.formsIndexSQL);
        """)
    }

    func setMaximumDatabaseBytes(_ maximumBytes: Int64) throws {
        guard maximumBytes > 0 else {
            throw VocabularyPackError.limitExceeded("database byte limit must be positive")
        }
        let pageSize = try scalarInt("PRAGMA page_size;")
        guard pageSize > 0 else {
            throw VocabularyPackError.databaseFailure("SQLite reported an invalid page size.")
        }
        let maximumPages = maximumBytes / pageSize
        guard maximumPages > 0 else {
            throw VocabularyPackError.limitExceeded("database byte limit is smaller than one SQLite page")
        }
        let appliedPages = try scalarInt("PRAGMA max_page_count = \(maximumPages);")
        guard appliedPages <= maximumPages else {
            throw VocabularyPackError.limitExceeded("database schema already exceeds byte limit")
        }
    }

    func begin() throws { try execute("BEGIN IMMEDIATE;") }
    func commit() throws { try execute("COMMIT;") }
    func rollback() { try? execute("ROLLBACK;") }

    func insert(_ entry: LexicalEntry, encoded: Data) throws {
        let sql = "INSERT INTO entries(id, language, canonical, search_key, frequency, payload) VALUES(?, ?, ?, ?, ?, ?);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(entry.id, at: 1, to: statement)
        try bindText(entry.language, at: 2, to: statement)
        try bindText(entry.canonicalForm.text.value, at: 3, to: statement)
        try bindText(VocabularySearchKey.make(entry.canonicalForm.text.value), at: 4, to: statement)
        if let frequency = entry.frequency {
            guard sqlite3_bind_double(statement, 5, frequency) == SQLITE_OK else { throw sqliteError() }
        } else {
            guard sqlite3_bind_null(statement, 5) == SQLITE_OK else { throw sqliteError() }
        }
        try bindBlob(encoded, at: 6, to: statement)
        let code = sqlite3_step(statement)
        if code & 0xFF == SQLITE_CONSTRAINT {
            throw VocabularyPackError.duplicateEntryID(entry.id)
        }
        guard code == SQLITE_DONE else { throw sqliteError(code) }

        let forms = [entry.canonicalForm] + entry.forms
        let formSQL = "INSERT INTO entry_forms(entry_id, ordinal, language, value, search_key) VALUES(?, ?, ?, ?, ?);"
        let formStatement = try prepare(formSQL)
        defer { sqlite3_finalize(formStatement) }
        for (ordinal, form) in forms.enumerated() {
            sqlite3_reset(formStatement)
            sqlite3_clear_bindings(formStatement)
            try bindText(entry.id, at: 1, to: formStatement)
            guard sqlite3_bind_int64(formStatement, 2, Int64(ordinal)) == SQLITE_OK else { throw sqliteError() }
            if let language = form.text.language {
                try bindText(language, at: 3, to: formStatement)
            } else {
                guard sqlite3_bind_null(formStatement, 3) == SQLITE_OK else { throw sqliteError() }
            }
            try bindText(form.text.value, at: 4, to: formStatement)
            try bindText(VocabularySearchKey.make(form.text.value), at: 5, to: formStatement)
            guard sqlite3_step(formStatement) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func validateForReading(expectedEntries: Int) throws {
        guard try scalarInt("PRAGMA application_id;") == Int64(Self.applicationID) else {
            throw VocabularyPackError.invalidPackage("Unexpected SQLite application ID.")
        }
        let version = try scalarInt("PRAGMA user_version;")
        guard version == Int64(Self.schemaVersion) else {
            throw VocabularyPackError.unsupportedVersion(Int(version))
        }
        guard try scalarText("PRAGMA quick_check(1);") == "ok" else {
            throw VocabularyPackError.invalidPackage("SQLite integrity check failed.")
        }
        let expectedObjects = [
            "index:entries_search_key_idx",
            "index:entry_forms_search_key_idx",
            "table:entries",
            "table:entry_forms",
        ]
        guard try schemaObjects() == expectedObjects else {
            throw VocabularyPackError.invalidPackage("SQLite contains an unexpected schema.")
        }
        guard try tableColumns("entries") == [
            "id:TEXT:1:1", "language:TEXT:1:0", "canonical:TEXT:1:0",
            "search_key:TEXT:1:0", "frequency:REAL:0:0", "payload:BLOB:1:0",
        ], try tableColumns("entry_forms") == [
            "entry_id:TEXT:1:1", "ordinal:INTEGER:1:2", "language:TEXT:0:0",
            "value:TEXT:1:0", "search_key:TEXT:1:0",
        ] else {
            throw VocabularyPackError.invalidPackage("SQLite table columns do not match the pack format.")
        }
        let expectedSQL = [
            "entries": Self.entriesTableSQL,
            "entry_forms": Self.formsTableSQL,
            "entries_search_key_idx": Self.entriesIndexSQL,
            "entry_forms_search_key_idx": Self.formsIndexSQL,
        ]
        for (name, sql) in expectedSQL {
            guard normalizeSchemaSQL(try schemaSQL(name: name)) == normalizeSchemaSQL(sql) else {
                throw VocabularyPackError.invalidPackage("SQLite schema definition for \(name) is unexpected.")
            }
        }
        guard try indexKeyColumns("entries_search_key_idx") == ["search_key", "language", "canonical"],
              try indexKeyColumns("entry_forms_search_key_idx") == ["search_key", "language", "entry_id"]
        else {
            throw VocabularyPackError.invalidPackage("SQLite search indexes are malformed.")
        }
        guard try scalarInt("SELECT COUNT(*) FROM entries;") == Int64(expectedEntries) else {
            throw VocabularyPackError.invalidPackage("Manifest entry count does not match database.")
        }
    }

    func entry(id: String, maximumEntryBytes: Int) throws -> LexicalEntry? {
        let statement = try prepare("SELECT payload FROM entries WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(id, at: 1, to: statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw sqliteError(code) }
        return try decodeEntry(statement: statement, column: 0, maximumBytes: maximumEntryBytes)
    }

    func search(
        key: String,
        mode: VocabularySearchMode,
        limit: Int,
        language: String?,
        maximumResultBytes: Int,
        maximumEntryBytes: Int
    ) throws -> [LexicalEntry] {
        let entryComparison: String
        let formComparison: String
        let searchValues: [String]
        switch mode {
        case .exact:
            entryComparison = "search_key = ?"
            formComparison = "f.search_key = ?"
            searchValues = [key]
        case .prefix:
            if let upperBound = prefixUpperBound(key) {
                entryComparison = "search_key >= ? AND search_key < ?"
                formComparison = "f.search_key >= ? AND f.search_key < ?"
                searchValues = [key, upperBound]
            } else {
                entryComparison = "search_key >= ?"
                formComparison = "f.search_key >= ?"
                searchValues = [key]
            }
        }
        let languageFilter = language == nil ? "" : " AND language = ?"
        let formLanguageFilter = language == nil ? "" : " AND COALESCE(f.language, e.language) = ?"
        let sql = """
        WITH candidates(id, canonical) AS (
            SELECT id, canonical FROM entries
            WHERE \(entryComparison)\(languageFilter)
            UNION
            SELECT e.id, e.canonical FROM entry_forms f JOIN entries e ON e.id = f.entry_id
            WHERE \(formComparison)\(formLanguageFilter)
        ), limited(id, canonical) AS (
            SELECT id, canonical FROM candidates
            ORDER BY canonical COLLATE NOCASE, id
            LIMIT ?
        )
        SELECT e.payload FROM limited l JOIN entries e ON e.id = l.id
        ORDER BY l.canonical COLLATE NOCASE, l.id;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for value in searchValues {
            try bindText(value, at: index, to: statement)
            index += 1
        }
        if let language {
            try bindText(language, at: index, to: statement)
            index += 1
        }
        for value in searchValues {
            try bindText(value, at: index, to: statement)
            index += 1
        }
        if let language {
            try bindText(language, at: index, to: statement)
            index += 1
        }
        guard sqlite3_bind_int64(statement, index, Int64(limit)) == SQLITE_OK else { throw sqliteError() }

        var result: [LexicalEntry] = []
        var resultBytes = 0
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw sqliteError(code) }
            let byteCount = Int(sqlite3_column_bytes(statement, 0))
            guard byteCount >= 0, byteCount <= maximumEntryBytes else {
                throw VocabularyPackError.limitExceeded("entry payload is too large")
            }
            let (newTotal, overflow) = resultBytes.addingReportingOverflow(byteCount)
            guard !overflow, newTotal <= maximumResultBytes else {
                throw VocabularyPackError.limitExceeded("search results exceed byte limit")
            }
            resultBytes = newTotal
            result.append(try decodeEntry(statement: statement, column: 0, maximumBytes: maximumEntryBytes))
        }
    }

    private func decodeEntry(
        statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int
    ) throws -> LexicalEntry {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw VocabularyPackError.invalidPackage("Entry payload is empty.")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= maximumBytes else {
            throw VocabularyPackError.limitExceeded("entry payload is too large")
        }
        let data = Data(bytes: bytes, count: count)
        do { return try decoder.decode(LexicalEntry.self, from: data) }
        catch { throw VocabularyPackError.invalidPackage("Entry payload is malformed: \(error.localizedDescription)") }
    }

    private func execute(_ sql: String) throws {
        guard let handle else { throw VocabularyPackError.databaseFailure("Database is closed.") }
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw sqliteError(code) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw VocabularyPackError.databaseFailure("Database is closed.") }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw sqliteError(code) }
        return statement
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw sqliteError()
        }
        return String(cString: value)
    }

    private func schemaObjects() throws -> [String] {
        let statement = try prepare(
            "SELECT type, name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name;"
        )
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW,
                  let type = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1)
            else { throw sqliteError(code) }
            result.append("\(String(cString: type)):\(String(cString: name))")
        }
    }

    private func tableColumns(_ table: String) throws -> [String] {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW,
                  let name = sqlite3_column_text(statement, 1),
                  let type = sqlite3_column_text(statement, 2)
            else { throw sqliteError(code) }
            result.append(
                "\(String(cString: name)):\(String(cString: type)):\(sqlite3_column_int(statement, 3)):\(sqlite3_column_int(statement, 5))"
            )
        }
    }

    private func schemaSQL(name: String) throws -> String {
        let statement = try prepare("SELECT sql FROM sqlite_schema WHERE name = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(name, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let sql = sqlite3_column_text(statement, 0) else {
            throw VocabularyPackError.invalidPackage("SQLite schema definition is missing.")
        }
        return String(cString: sql)
    }

    private func indexKeyColumns(_ indexName: String) throws -> [String] {
        guard indexName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw VocabularyPackError.invalidPackage("Invalid internal index name.")
        }
        let statement = try prepare("PRAGMA index_xinfo(\(indexName));")
        defer { sqlite3_finalize(statement) }
        var columns: [(sequence: Int, name: String)] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return columns.sorted { $0.sequence < $1.sequence }.map(\.name) }
            guard code == SQLITE_ROW else { throw sqliteError(code) }
            guard sqlite3_column_int(statement, 5) == 1 else { continue }
            guard let name = sqlite3_column_text(statement, 2) else {
                throw VocabularyPackError.invalidPackage("Search index contains an expression.")
            }
            columns.append((Int(sqlite3_column_int(statement, 0)), String(cString: name)))
        }
    }

    private func normalizeSchemaSQL(_ sql: String) -> String {
        sql.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let byteCount = value.utf8.count
        guard byteCount <= Int(Int32.max) else {
            throw VocabularyPackError.limitExceeded("SQLite text value is too large")
        }
        let code = value.withCString { bytes in
            sqlite3_bind_text(statement, index, bytes, Int32(byteCount), vocabularySQLiteTransient)
        }
        guard code == SQLITE_OK else { throw sqliteError(code) }
    }

    private func bindBlob(_ data: Data, at index: Int32, to statement: OpaquePointer) throws {
        let code = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), vocabularySQLiteTransient)
        }
        guard code == SQLITE_OK else { throw sqliteError(code) }
    }

    private func sqliteError(_ code: Int32? = nil) -> VocabularyPackError {
        guard let handle else {
            return .databaseFailure(code.map { String(cString: sqlite3_errstr($0)) } ?? "Database is closed.")
        }
        return .databaseFailure(String(cString: sqlite3_errmsg(handle)))
    }

    private func prefixUpperBound(_ prefix: String) -> String? {
        var scalars = Array(prefix.unicodeScalars)
        while let last = scalars.popLast() {
            let value = last.value
            let nextValue: UInt32?
            if value < 0xD7FF { nextValue = value + 1 }
            else if value == 0xD7FF { nextValue = 0xE000 }
            else if value < 0x10FFFF { nextValue = value + 1 }
            else { nextValue = nil }
            if let nextValue, let next = UnicodeScalar(nextValue) {
                scalars.append(next)
                return String(String.UnicodeScalarView(scalars))
            }
        }
        return nil
    }
}

private let vocabularySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
