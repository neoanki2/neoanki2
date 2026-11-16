import Foundation

/// A single-root, text-content authored source for native generators. External
/// packages continue through the confined file reader; both use one compiler.
public struct AuthoredDeckDraft: Sendable {
    public struct Field: Encodable, Sendable {
        public let id: String
        public let name: String
        public let type: FieldType
        public let required: Bool
        public init(id: String, name: String, type: FieldType = .text, required: Bool = true) {
            self.id = id; self.name = name; self.type = type; self.required = required
        }
    }
    public struct Slot: Encodable, Sendable {
        public let field: String
        public let reveal: RevealMode?
        public init(field: String, reveal: RevealMode? = nil) {
            self.field = field; self.reveal = reveal
        }
    }
    public struct Component: Encodable, Sendable {
        public let region: ComponentRegion
        public let purpose: ComponentPurpose
        public let field: String
        public let reveal: RevealMode
        public init(region: ComponentRegion, purpose: ComponentPurpose, field: String,
                    reveal: RevealMode = .always) {
            self.region = region; self.purpose = purpose; self.field = field; self.reveal = reveal
        }
    }
    public struct CardTemplate: Encodable, Sendable {
        public let name: String
        public let layout: CardLayoutID
        public let components: [Component]
        public var prompt: [Slot] { components.filter { $0.purpose != .expectedAnswer }.map(Self.slot) }
        public var answer: [Slot] { components.filter { $0.purpose == .expectedAnswer }.map(Self.slot) }
        private static func slot(_ component: Component) -> Slot {
            Slot(field: component.field, reveal: component.reveal == .always ? nil : component.reveal)
        }
        public let interaction: Interaction
        public let skill: Skill
        public init(name: String, layout: CardLayoutID, components: [Component],
                    interaction: Interaction, skill: Skill) {
            self.name = name; self.layout = layout; self.components = components
            self.interaction = interaction; self.skill = skill
        }
        private enum CodingKeys: String, CodingKey { case name, layout, components, prompt, answer, interaction, skill }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(name, forKey: .name)
            try values.encode(layout, forKey: .layout)
            try values.encode(components, forKey: .components)
            try values.encode(prompt, forKey: .prompt)
            try values.encode(answer, forKey: .answer)
            try values.encode(interaction, forKey: .interaction)
            try values.encode(skill, forKey: .skill)
        }
    }
    public struct Definition: Encodable, Sendable {
        private let kind = "type"
        public let id: String
        public let name: String
        public let fields: [Field]
        public let templates: [CardTemplate]
        public init(id: String, name: String, fields: [Field], templates: [CardTemplate]) {
            self.id = id; self.name = name; self.fields = fields; self.templates = templates
        }
    }
    public struct TextItem: Sendable {
        public let fields: [String: String]
        public let tags: [String]
        public init(fields: [String: String], tags: [String] = []) {
            self.fields = fields; self.tags = tags
        }
    }
    public let key: String
    public let title: String
    public let definition: Definition
    public let items: [TextItem]
    public init(key: String, title: String, definition: Definition, items: [TextItem]) {
        self.key = key; self.title = title; self.definition = definition; self.items = items
    }

    var partName: String { "items/\(key).jsonl" }

    /// One writer supplies both counting validation and legacy exports. A line
    /// is encoded at a time, so validation needs neither a file nor a full copy
    /// of all serialized item data.
    func writeRecords(_ emit: (String, Int, Data) throws -> Void) throws {
        struct Header: Encodable { let kind = "neoanki"; let version = 5; let root: String; let parts: [String] }
        struct Root: Encodable { let kind = "deck"; let id: String; let name: String; let itemTypes: [String]; let defaultType: String }
        struct Text: Encodable { let text: String }
        struct Record: Encodable { let kind = "item"; let deck: String; let type: String; let fields: [String: Text]; let tags: [String] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        func line<T: Encodable>(_ value: T, file: String, number: Int) throws {
            try Task.checkCancellation()
            var data = try encoder.encode(value); data.append(0x0a)
            try emit(file, number, data)
        }
        try line(Header(root: key, parts: [partName]), file: AuthoredDeck.manifestName, number: 1)
        try line(definition, file: AuthoredDeck.manifestName, number: 2)
        try line(Root(id: key, name: title, itemTypes: [definition.id], defaultType: definition.id),
                 file: AuthoredDeck.manifestName, number: 3)
        for (index, item) in items.enumerated() {
            try line(Record(deck: key, type: definition.id,
                            fields: item.fields.mapValues { Text(text: $0) }, tags: item.tags),
                     file: partName, number: index + 1)
        }
    }
}
