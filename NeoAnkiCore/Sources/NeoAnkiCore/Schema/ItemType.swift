import Foundation

/// The schema shared by many items: the fields they hold and the templates
/// that turn them into cards. This is the unit users customize to model any
/// subject; the app can ship with zero built-in item types.
public struct ItemType: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var fields: [FieldDef]
    public var templates: [Template]
    private var listDefinitions: [ItemList]?

    public var lists: [ItemList] {
        get { listDefinitions ?? [] }
        set { listDefinitions = newValue.isEmpty ? nil : newValue }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        fields: [FieldDef],
        templates: [Template],
        lists: [ItemList] = []
    ) {
        self.id = id
        self.name = name
        self.fields = fields
        self.templates = templates
        listDefinitions = lists.isEmpty ? nil : lists
    }

    public func field(_ id: UUID) -> FieldDef? {
        fields.first { $0.id == id }
    }

    public func field(named name: String) -> FieldDef? {
        fields.first { $0.name == name }
    }

    public func sourceField(_ id: UUID) -> FieldDef? {
        field(id) ?? lists.lazy.flatMap(\.columns).first { $0.id == id }
    }
}
