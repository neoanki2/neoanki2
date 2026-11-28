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
    public enum Cell: Encodable, Sendable {
        case text(String), number(Double), checkbox(Bool), cloze(String), richText([String])

        private enum CodingKeys: String, CodingKey { case text, number, checkbox, cloze, rich }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text): try values.encode(text, forKey: .text)
            case let .number(number): try values.encode(number, forKey: .number)
            case let .checkbox(checked): try values.encode(checked, forKey: .checkbox)
            case let .cloze(text): try values.encode(text, forKey: .cloze)
            case let .richText(spans): try values.encode(spans.map { ["text": $0] }, forKey: .rich)
            }
        }
    }
    public struct Row: Encodable, Sendable {
        public let id: UUID
        public let fields: [String: Cell]
        public init(id: UUID = UUID(), fields: [String: Cell]) {
            self.id = id
            self.fields = fields
        }
    }
    public struct List: Encodable, Sendable {
        public let id: String
        public let name: String
        public let columns: [Field]
        public let sharedRows: [Row]?
        public init(id: String, name: String, columns: [Field], sharedRows: [Row]? = nil) {
            self.id = id
            self.name = name
            self.columns = columns
            self.sharedRows = sharedRows
        }
    }
    public struct CardCreation: Encodable, Sendable {
        public let lists: [String]
        public let checked: [String]
        public let startSuspended: Bool
        public init(lists: [String] = [], checked: [String] = [], startSuspended: Bool = false) {
            self.lists = lists
            self.checked = checked
            self.startSuspended = startSuspended
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
        public let fitStudyArea: Bool
        public let createCardsFrom: CardCreation?
        public let response: ResponseMode?
        public init(name: String, layout: CardLayoutID, components: [Component],
                    interaction: Interaction, skill: Skill, fitStudyArea: Bool = false,
                    createCardsFrom: CardCreation? = nil, response: ResponseMode? = nil) {
            self.name = name; self.layout = layout; self.components = components
            self.interaction = interaction; self.skill = skill
            self.fitStudyArea = fitStudyArea
            self.createCardsFrom = createCardsFrom
            self.response = response
        }
        private enum CodingKeys: String, CodingKey { case name, layout, components, prompt, answer, interaction, skill, fitStudyArea, createCardsFrom, response }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(name, forKey: .name)
            try values.encode(layout, forKey: .layout)
            try values.encode(components, forKey: .components)
            try values.encode(prompt, forKey: .prompt)
            try values.encode(answer, forKey: .answer)
            try values.encode(interaction, forKey: .interaction)
            try values.encode(skill, forKey: .skill)
            try values.encode(fitStudyArea, forKey: .fitStudyArea)
            try values.encodeIfPresent(createCardsFrom, forKey: .createCardsFrom)
            try values.encodeIfPresent(response, forKey: .response)
        }
    }
    public struct Definition: Encodable, Sendable {
        private let kind = "type"
        public let id: String
        public let name: String
        public let fields: [Field]
        public let templates: [CardTemplate]
        public let lists: [List]?
        public init(id: String, name: String, fields: [Field], templates: [CardTemplate], lists: [List]? = nil) {
            self.id = id; self.name = name; self.fields = fields; self.templates = templates
            self.lists = lists
        }
    }
    public struct TextItem: Sendable {
        public let fields: [String: String]
        public let tags: [String]
        public let listRows: [String: [Row]]
        public init(fields: [String: String], tags: [String] = [], listRows: [String: [Row]] = [:]) {
            self.fields = fields
            self.tags = tags
            self.listRows = listRows
        }
    }
    public let key: String
    public let title: String
    public let definition: Definition
    public let items: [TextItem]
    public init(key: String, title: String, definition: Definition, items: [TextItem]) {
        self.key = key; self.title = title; self.definition = definition; self.items = items
    }

    var sourceVersion: Int {
        if definition.lists != nil || definition.templates.contains(where: { $0.createCardsFrom != nil || $0.response != nil })
            || items.contains(where: { !$0.listRows.isEmpty }) { return 7 }
        return 5
    }

    var partName: String { "items/\(key).jsonl" }

    /// One writer supplies both counting validation and legacy exports. A line
    /// is encoded at a time, so validation needs neither a file nor a full copy
    /// of all serialized item data.
    func writeRecords(_ emit: (String, Int, Data) throws -> Void) throws {
        struct Header: Encodable { let kind = "neoanki"; let version: Int; let root: String; let parts: [String] }
        struct Root: Encodable { let kind = "deck"; let id: String; let name: String; let itemTypes: [String]; let defaultType: String }
        struct Text: Encodable { let text: String }
        struct Record: Encodable { let kind = "item"; let deck: String; let type: String; let fields: [String: Text]; let tags: [String]; let lists: [String: [Row]]? }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        func line<T: Encodable>(_ value: T, file: String, number: Int) throws {
            try Task.checkCancellation()
            var data = try encoder.encode(value); data.append(0x0a)
            try emit(file, number, data)
        }
        try line(Header(version: sourceVersion, root: key, parts: [partName]), file: AuthoredDeck.manifestName, number: 1)
        try line(definition, file: AuthoredDeck.manifestName, number: 2)
        try line(Root(id: key, name: title, itemTypes: [definition.id], defaultType: definition.id),
                 file: AuthoredDeck.manifestName, number: 3)
        for (index, item) in items.enumerated() {
            try line(Record(deck: key, type: definition.id,
                            fields: item.fields.mapValues { Text(text: $0) }, tags: item.tags,
                            lists: item.listRows.isEmpty ? nil : item.listRows),
                     file: partName, number: index + 1)
        }
    }
}
