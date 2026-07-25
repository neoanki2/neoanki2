import Foundation

/// One row to import into an existing item type.
public struct ImportRow: Sendable, Equatable {
    public var fieldValues: [String: String]
    public var structuredFields: [String: StructuredFieldValue]
    public var tags: [String]

    public init(
        fieldValues: [String: String] = [:],
        structuredFields: [String: StructuredFieldValue] = [:],
        tags: [String] = []
    ) {
        self.fieldValues = fieldValues
        self.structuredFields = structuredFields
        self.tags = tags
    }
}

/// Parsed import payload targeting an item type by name.
public struct ImportPayload: Sendable, Equatable {
    public var itemTypeName: String
    public var rows: [ImportRow]

    public init(itemTypeName: String, rows: [ImportRow]) {
        self.itemTypeName = itemTypeName
        self.rows = rows
    }
}

public enum ImportError: Error, Sendable, Equatable, LocalizedError {
    case invalidFormat(String)
    case unknownField(String)
    case emptyPayload
    case itemTypeNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidFormat(message):
            return "Invalid import format: \(message)"
        case let .unknownField(name):
            return "Unknown field: \(name)"
        case .emptyPayload:
            return "Import contains no rows."
        case let .itemTypeNotFound(name):
            return "Item type not found: \(name)"
        }
    }
}

public struct ImportContext: Sendable {
    public var baseDirectory: URL?

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
    }
}

/// Parses native NeoAnki import data (JSON or CSV) into rows for `ItemStore`.
public protocol ImportAdapter: Sendable {
    /// Whether the source format can represent cloze and media objects.
    var supportsStructuredFields: Bool { get }
    func parse(_ data: Data) throws -> ImportPayload
}

public extension ImportAdapter {
    var supportsStructuredFields: Bool { true }
}

/// Native JSON import format:
/// `{ "itemType": "Basic", "rows": [ { "Front": "Q", "Back": "A", "tags": ["x"] } ] }`
public struct JSONImportAdapter: ImportAdapter {
    private struct Payload: Decodable {
        var itemType: String
        var rows: [Row]

        struct Row: Decodable {
            let values: [String: String]
            let structured: [String: StructuredFieldValue]
            let tags: [String]

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: DynamicKey.self)
                var values: [String: String] = [:]
                var structured: [String: StructuredFieldValue] = [:]
                var tags: [String] = []

                for key in container.allKeys {
                    if key.stringValue == "tags" {
                        tags = try container.decodeIfPresent([String].self, forKey: key) ?? []
                    } else if let string = try? container.decode(String.self, forKey: key) {
                        values[key.stringValue] = string
                    } else if let structuredValue = try? container.decode(StructuredFieldValue.self, forKey: key) {
                        structured[key.stringValue] = structuredValue
                    }
                }

                self.values = values
                self.structured = structured
                self.tags = tags
            }
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            nil
        }
    }

    public init() {}

    public func parse(_ data: Data) throws -> ImportPayload {
        let decoder = JSONDecoder()
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw ImportError.invalidFormat("The JSON structure is invalid.")
        }

        guard !payload.rows.isEmpty else {
            throw ImportError.emptyPayload
        }

        let rows = payload.rows.map { row in
            ImportRow(fieldValues: row.values, structuredFields: row.structured, tags: row.tags)
        }
        return ImportPayload(itemTypeName: payload.itemType, rows: rows)
    }
}

/// CSV with a header row. Optional `tags` column contains comma-separated tags.
public struct CSVImportAdapter: ImportAdapter {
    public var itemTypeName: String
    public var supportsStructuredFields: Bool { false }

    public init(itemTypeName: String) {
        self.itemTypeName = itemTypeName
    }

    public func parse(_ data: Data) throws -> ImportPayload {
        try ImportLimits.validatePayloadSize(data)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidFormat("Expected UTF-8 text.")
        }

        let records = try parseRecords(text)
        guard records.count >= 2 else {
            throw ImportError.emptyPayload
        }

        let headers = records[0].map { $0.trimmingCharacters(in: .whitespaces) }
        guard !headers.isEmpty, headers.allSatisfy({ !$0.isEmpty }) else {
            throw ImportError.invalidFormat("Missing CSV header.")
        }
        guard Set(headers).count == headers.count else {
            throw ImportError.invalidFormat("CSV header names must be unique.")
        }

        var rows: [ImportRow] = []
        rows.reserveCapacity(records.count - 1)

        for values in records.dropFirst() {
            guard values.count == headers.count else {
                throw ImportError.invalidFormat("Every CSV row must have \(headers.count) fields.")
            }

            var fieldValues: [String: String] = [:]
            var tags: [String] = []

            for (index, header) in headers.enumerated() {
                guard index < values.count else { break }
                if header == "tags" {
                    tags = values[index]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                } else {
                    fieldValues[header] = values[index]
                }
            }

            rows.append(ImportRow(fieldValues: fieldValues, tags: tags))
        }

        guard !rows.isEmpty else {
            throw ImportError.emptyPayload
        }

        return ImportPayload(itemTypeName: itemTypeName, rows: rows)
    }

    private enum CSVState {
        case fieldStart
        case unquoted
        case quoted
        case afterQuote
    }

    private func parseRecords(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var fieldBytes = 0
        var state = CSVState.fieldStart
        var index = text.startIndex

        func appendField() throws {
            guard record.count < ImportLimits.maxFieldsPerRow else {
                throw ImportError.invalidFormat(
                    "CSV rows may contain at most \(ImportLimits.maxFieldsPerRow) fields."
                )
            }
            record.append(field)
            field = ""
            fieldBytes = 0
        }

        func appendRecord() throws {
            try appendField()
            if !record.allSatisfy(\.isEmpty) {
                guard records.count < ImportLimits.maxRows + 1 else {
                    throw ImportError.invalidFormat("Import exceeds \(ImportLimits.maxRows) row limit.")
                }
                records.append(record)
            }
            record = []
        }

        func append(_ character: Character) throws {
            fieldBytes += String(character).utf8.count
            guard fieldBytes <= ImportLimits.maxFieldStringBytes else {
                throw ImportError.invalidFormat("A CSV field exceeds maximum length.")
            }
            field.append(character)
        }

        while index < text.endIndex {
            let character = text[index]

            switch state {
            case .fieldStart:
                if character == "\"" {
                    state = .quoted
                } else if character == "," {
                    try appendField()
                } else if character.isNewline {
                    try appendRecord()
                } else {
                    try append(character)
                    state = .unquoted
                }
            case .unquoted:
                if character == "," {
                    try appendField()
                    state = .fieldStart
                } else if character.isNewline {
                    try appendRecord()
                    state = .fieldStart
                } else if character == "\"" {
                    throw ImportError.invalidFormat("Quotes must enclose an entire CSV field.")
                } else {
                    try append(character)
                }
            case .quoted:
                if character == "\"" {
                    state = .afterQuote
                } else if character.isNewline {
                    try append("\n")
                } else {
                    try append(character)
                }
            case .afterQuote:
                if character == "\"" {
                    try append("\"")
                    state = .quoted
                } else if character == "," {
                    try appendField()
                    state = .fieldStart
                } else if character.isNewline {
                    try appendRecord()
                    state = .fieldStart
                } else {
                    throw ImportError.invalidFormat("Unexpected text after a closing CSV quote.")
                }
            }

            index = text.index(after: index)
        }

        guard state != .quoted else {
            throw ImportError.invalidFormat("A quoted CSV field is not closed.")
        }
        if state != .fieldStart || !field.isEmpty || !record.isEmpty {
            try appendRecord()
        }
        return records
    }
}
