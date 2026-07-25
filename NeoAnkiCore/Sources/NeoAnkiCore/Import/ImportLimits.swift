import Foundation

public enum ImportLimits {
    public static let maxPayloadBytes = 5_000_000
    public static let maxRows = 10_000
    public static let maxFieldStringLength = 32_768

    public static func validatePayloadSize(_ data: Data) throws {
        guard data.count <= maxPayloadBytes else {
            throw ImportError.invalidFormat("Import file exceeds \(maxPayloadBytes / 1_000_000) MB limit.")
        }
    }

    public static func validateRowCount(_ count: Int) throws {
        guard count <= maxRows else {
            throw ImportError.invalidFormat("Import exceeds \(maxRows) row limit.")
        }
    }

    public static func validateFieldString(_ value: String, fieldName: String) throws {
        guard value.count <= maxFieldStringLength else {
            throw ImportError.invalidFormat("Field \"\(fieldName)\" exceeds maximum length.")
        }
    }
}

/// Structured JSON cell for non-scalar field values.
public enum StructuredFieldValue: Decodable, Sendable, Equatable {
    case text(String)
    case cloze(text: String, blanks: [ClozeSpan])
    case mediaPath(String)
    case mediaBase64(String, fileExtension: String)

    private enum CodingKeys: String, CodingKey {
        case text, blanks, path, base64, fileExtension
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let string = try? single.decode(String.self) {
            self = .text(string)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .path) {
            self = .mediaPath(path)
            return
        }
        if let base64 = try container.decodeIfPresent(String.self, forKey: .base64) {
            let ext = try container.decodeIfPresent(String.self, forKey: .fileExtension) ?? "bin"
            self = .mediaBase64(base64, fileExtension: ext)
            return
        }

        let text = try container.decode(String.self, forKey: .text)
        let blanks = try container.decodeIfPresent([ClozeSpan].self, forKey: .blanks) ?? []
        if blanks.isEmpty {
            self = .text(text)
        } else {
            self = .cloze(text: text, blanks: blanks)
        }
    }
}
