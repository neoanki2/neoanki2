import Foundation

/// The schema shared by many notes: the fields they hold and the templates
/// that turn them into cards. This is the unit users customize to model any
/// subject; the app can ship with zero built-in note types.
public struct NoteType: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var fields: [FieldDef]
    public var templates: [CardTemplate]

    public init(
        id: UUID = UUID(),
        name: String,
        fields: [FieldDef],
        templates: [CardTemplate]
    ) {
        self.id = id
        self.name = name
        self.fields = fields
        self.templates = templates
    }

    public func field(_ id: UUID) -> FieldDef? {
        fields.first { $0.id == id }
    }
}
