import Foundation

/// One row to import into an existing item type.
public struct ImportRow: Sendable, Equatable {
    public var fieldValues: [String: String]
    public var tags: [String]

    public init(fieldValues: [String: String], tags: [String] = []) {
        self.fieldValues = fieldValues
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

/// Parses native NeoAnki import data (JSON or CSV) into rows for `ItemStore`.
public protocol ImportAdapter: Sendable {
    func parse(_ data: Data) throws -> ImportPayload
}

/// Native JSON import format:
/// `{ "itemType": "Basic", "rows": [ { "Front": "Q", "Back": "A", "tags": ["x"] } ] }`
public struct JSONImportAdapter: ImportAdapter {
    private struct Payload: Decodable {
        var itemType: String
        var rows: [Row]

        struct Row: Decodable {
            let values: [String: String]
            let tags: [String]

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: DynamicKey.self)
                var values: [String: String] = [:]
                var tags: [String] = []

                for key in container.allKeys {
                    if key.stringValue == "tags" {
                        tags = try container.decodeIfPresent([String].self, forKey: key) ?? []
                    } else if let string = try container.decodeIfPresent(String.self, forKey: key) {
                        values[key.stringValue] = string
                    }
                }

                self.values = values
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
            throw ImportError.invalidFormat(error.localizedDescription)
        }

        guard !payload.rows.isEmpty else {
            throw ImportError.emptyPayload
        }

        let rows = payload.rows.map { row in
            ImportRow(fieldValues: row.values, tags: row.tags)
        }
        return ImportPayload(itemTypeName: payload.itemType, rows: rows)
    }
}

/// CSV with a header row. Optional `tags` column contains comma-separated tags.
public struct CSVImportAdapter: ImportAdapter {
    public var itemTypeName: String

    public init(itemTypeName: String) {
        self.itemTypeName = itemTypeName
    }

    public func parse(_ data: Data) throws -> ImportPayload {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidFormat("Expected UTF-8 text.")
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            throw ImportError.emptyPayload
        }

        let headers = parseCSVLine(lines[0])
        guard !headers.isEmpty else {
            throw ImportError.invalidFormat("Missing CSV header.")
        }

        var rows: [ImportRow] = []
        rows.reserveCapacity(lines.count - 1)

        for line in lines.dropFirst() {
            let values = parseCSVLine(line)
            guard !values.isEmpty else { continue }

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

    private func parseCSVLine(_ line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }

        values.append(current.trimmingCharacters(in: .whitespaces))
        return values
    }
}
