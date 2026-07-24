import Foundation

/// A concrete piece of knowledge: values for the fields of its `NoteType`.
/// A note holds content once; cards are generated from it per template, so
/// editing the note updates every card that draws from it.
public struct Note: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var noteTypeID: UUID
    public var fields: [FieldValue]
    public var tags: [String]
    public var deckID: UUID?

    public init(
        id: UUID = UUID(),
        noteTypeID: UUID,
        fields: [FieldValue],
        tags: [String] = [],
        deckID: UUID? = nil
    ) {
        self.id = id
        self.noteTypeID = noteTypeID
        self.fields = fields
        self.tags = tags
        self.deckID = deckID
    }

    public func value(for fieldID: UUID) -> ContentValue? {
        fields.first { $0.fieldID == fieldID }?.value
    }

    public func isFieldEmpty(_ fieldID: UUID) -> Bool {
        value(for: fieldID)?.isEmpty ?? true
    }
}

/// One field's content on a note. Stored as an array (not a dictionary) so it
/// serializes to clean, stable JSON keyed by the field's UUID.
public struct FieldValue: Codable, Equatable, Sendable {
    public var fieldID: UUID
    public var value: ContentValue

    public init(fieldID: UUID, value: ContentValue) {
        self.fieldID = fieldID
        self.value = value
    }
}
