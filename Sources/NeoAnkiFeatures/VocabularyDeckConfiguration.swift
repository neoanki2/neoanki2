import Foundation
import NeoAnkiCore

/// A semantic source, never a language-specific card recipe.
public enum VocabularyFieldSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case manual, typedWord, headword, form, pronunciationText, pronunciationAudio, meaning, example
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .manual: "Enter manually"
        case .typedWord: "Typed word"
        case .headword: "Dictionary headword"
        case .form: "Dictionary form"
        case .pronunciationText: "Pronunciation text"
        case .pronunciationAudio: "Pronunciation audio"
        case .meaning: "Meaning"
        case .example: "Example"
        }
    }
    public func supports(_ type: FieldType) -> Bool {
        if self == .manual { return true }
        if self == .pronunciationAudio { return type == .audio }
        return type == .text || type == .richText
    }
}

public struct VocabularyFieldBinding: Codable, Sendable, Equatable {
    public var fieldID: UUID
    public var fieldType: FieldType
    public var source: VocabularyFieldSource
    /// A source-defined pronunciation scheme or form kind; never an entry ID.
    public var variant: String?
    public var language: String?
    public init(fieldID: UUID, fieldType: FieldType, source: VocabularyFieldSource = .manual,
                variant: String? = nil, language: String? = nil) {
        self.fieldID = fieldID; self.fieldType = fieldType; self.source = source
        self.variant = variant; self.language = language
    }
}

public struct VocabularyDeckConfiguration: Codable, Sendable, Equatable {
    public var dictionaryID: String
    public var deckID: UUID
    public var itemTypeID: UUID
    public var bindings: [VocabularyFieldBinding]
    public init(dictionaryID: String, deckID: UUID, itemTypeID: UUID, bindings: [VocabularyFieldBinding]) {
        self.dictionaryID = dictionaryID; self.deckID = deckID
        self.itemTypeID = itemTypeID; self.bindings = bindings
    }
    public func issue(itemTypes: [ItemType]) -> String? {
        guard let type = itemTypes.first(where: { $0.id == itemTypeID }) else {
            return "This card setup was deleted. Choose another item type."
        }
        guard Set(bindings.map(\.fieldID)).count == bindings.count,
              bindings.allSatisfy({ binding in
                  type.fields.contains { $0.id == binding.fieldID && $0.type == binding.fieldType }
                      && binding.source.supports(binding.fieldType)
              }), Set(bindings.map(\.fieldID)) == Set(type.fields.map(\.id)) else {
            return "The fields in this card setup changed. Review the field mappings."
        }
        if let field = type.fields.first(where: { $0.isRequired && ![.text, .richText, .number, .audio].contains($0.type) }) {
            return "\(field.name) requires the full item editor. Choose a text or audio card setup for quick capture."
        }
        if let field = type.fields.first(where: { field in
            field.isRequired && field.type == .audio && bindings.first(where: { $0.fieldID == field.id })?.source != .pronunciationAudio
        }) {
            return "Map \(field.name) to dictionary pronunciation audio, or use the full item editor."
        }
        return nil
    }
}

public struct VocabularyCapturePreferences: Codable, Sendable, Equatable {
    public var configurations: [VocabularyDeckConfiguration] = []
    public var lastDeckID: UUID?
    public var lastDictionaryByDeck: [UUID: String] = [:]
    public init() {}
    public func configuration(dictionaryID: String?, deckID: UUID?) -> VocabularyDeckConfiguration? {
        configurations.first { $0.dictionaryID == dictionaryID && $0.deckID == deckID }
    }
    public mutating func set(_ configuration: VocabularyDeckConfiguration) {
        configurations.removeAll { $0.dictionaryID == configuration.dictionaryID && $0.deckID == configuration.deckID }
        configurations.append(configuration)
        remember(dictionaryID: configuration.dictionaryID, deckID: configuration.deckID)
    }
    public mutating func remember(dictionaryID: String, deckID: UUID) {
        lastDeckID = deckID; lastDictionaryByDeck[deckID] = dictionaryID
    }
}

@MainActor public protocol VocabularyDeckConfigurationStoring {
    func load(libraryID: UUID) throws -> VocabularyCapturePreferences
    func save(_ preferences: VocabularyCapturePreferences, libraryID: UUID) throws
}

/// Device-local preferences deliberately live outside the synchronized database and packs.
@MainActor public final class FileVocabularyDeckConfigurationStore: VocabularyDeckConfigurationStoring {
    private let rootURL: URL
    public init(rootURL: URL) { self.rootURL = rootURL }
    public func load(libraryID: UUID) throws -> VocabularyCapturePreferences {
        let url = rootURL.appendingPathComponent("\(libraryID).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(VocabularyCapturePreferences.self, from: Data(contentsOf: url))
    }
    public func save(_ preferences: VocabularyCapturePreferences, libraryID: UUID) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: rootURL.appendingPathComponent("\(libraryID).json"), options: .atomic)
    }
}
