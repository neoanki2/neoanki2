import CryptoKit
import Foundation

/// UUID-independent, ordered representation of an item type for portable-deck
/// identity. Names are preserved verbatim because they are part of the schema.
public struct CanonicalItemType: Codable, Equatable, Sendable {
    public let name: String
    public let fields: [CanonicalField]
    public let templates: [CanonicalTemplate]

    public init(name: String, fields: [CanonicalField], templates: [CanonicalTemplate]) {
        self.name = name
        self.fields = fields
        self.templates = templates
    }
}

public struct CanonicalField: Codable, Equatable, Sendable {
    public let name: String
    public let type: FieldType
    public let isRequired: Bool

    public init(name: String, type: FieldType, isRequired: Bool) {
        self.name = name
        self.type = type
        self.isRequired = isRequired
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type = "kind"
        case isRequired = "required"
    }
}

public struct CanonicalTemplate: Codable, Equatable, Sendable {
    public let name: String
    public let prompt: CanonicalSide
    public let answer: CanonicalSide
    public let interaction: Interaction
    public let skill: Skill
    public let generateWhen: CanonicalSlotCondition?

    public init(
        name: String,
        prompt: CanonicalSide,
        answer: CanonicalSide,
        interaction: Interaction,
        skill: Skill,
        generateWhen: CanonicalSlotCondition?
    ) {
        self.name = name
        self.prompt = prompt
        self.answer = answer
        self.interaction = interaction
        self.skill = skill
        self.generateWhen = generateWhen
    }
}

public struct CanonicalSide: Codable, Equatable, Sendable {
    public let slots: [CanonicalSlot]

    public init(slots: [CanonicalSlot]) {
        self.slots = slots
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        slots = try container.decode([CanonicalSlot].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(slots)
    }
}

public struct CanonicalSlot: Codable, Equatable, Sendable {
    public let source: CanonicalSlotSource
    public let presentation: Presentation

    public init(source: CanonicalSlotSource, presentation: Presentation) {
        self.source = source
        self.presentation = presentation
    }
}

public enum CanonicalSlotSource: Codable, Equatable, Sendable {
    case field(ordinal: Int)
    case literal(String)

    private enum CodingKeys: String, CodingKey {
        case field
        case literal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ordinal = try container.decodeIfPresent(Int.self, forKey: .field) {
            self = .field(ordinal: ordinal)
        } else {
            self = .literal(try container.decode(String.self, forKey: .literal))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .field(ordinal):
            try container.encode(ordinal, forKey: .field)
        case let .literal(value):
            try container.encode(value, forKey: .literal)
        }
    }
}

public indirect enum CanonicalSlotCondition: Codable, Equatable, Sendable {
    case fieldNotEmpty(ordinal: Int)
    case fieldEmpty(ordinal: Int)
    case all([CanonicalSlotCondition])
    case any([CanonicalSlotCondition])

    private enum CodingKeys: String, CodingKey {
        case fieldNotEmpty
        case fieldEmpty
        case all
        case any
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ordinal = try container.decodeIfPresent(Int.self, forKey: .fieldNotEmpty) {
            self = .fieldNotEmpty(ordinal: ordinal)
        } else if let ordinal = try container.decodeIfPresent(Int.self, forKey: .fieldEmpty) {
            self = .fieldEmpty(ordinal: ordinal)
        } else if let conditions = try container.decodeIfPresent([Self].self, forKey: .all) {
            self = .all(conditions)
        } else {
            self = .any(try container.decode([Self].self, forKey: .any))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fieldNotEmpty(ordinal):
            try container.encode(ordinal, forKey: .fieldNotEmpty)
        case let .fieldEmpty(ordinal):
            try container.encode(ordinal, forKey: .fieldEmpty)
        case let .all(conditions):
            try container.encode(conditions, forKey: .all)
        case let .any(conditions):
            try container.encode(conditions, forKey: .any)
        }
    }
}

public enum PortableItemTypeIdentityError: Error, Equatable, Sendable {
    case duplicateFieldID(UUID)
    case unknownFieldReference(UUID)
}

/// Builds and hashes the canonical item-type schema used by Portable Deck
/// Format v1. SHA-256 here is an integrity/identity digest, not authentication.
public enum PortableItemTypeIdentity {
    public static func canonicalRepresentation(
        of itemType: ItemType
    ) throws -> CanonicalItemType {
        var ordinals: [UUID: Int] = [:]
        for (ordinal, field) in itemType.fields.enumerated() {
            guard ordinals.updateValue(ordinal, forKey: field.id) == nil else {
                throw PortableItemTypeIdentityError.duplicateFieldID(field.id)
            }
        }

        return CanonicalItemType(
            name: normalized(itemType.name),
            fields: itemType.fields.map {
                CanonicalField(
                    name: normalized($0.name),
                    type: $0.type,
                    isRequired: $0.isRequired
                )
            },
            templates: try itemType.templates.map { template in
                CanonicalTemplate(
                    name: normalized(template.name),
                    prompt: try canonicalSide(template.prompt, ordinals: ordinals),
                    answer: try canonicalSide(template.answer, ordinals: ordinals),
                    interaction: template.interaction,
                    skill: template.skill,
                    generateWhen: try template.generateWhen.map {
                        try canonicalCondition($0, ordinals: ordinals)
                    }
                )
            }
        )
    }

    /// Deterministic JSON with sorted object keys. Arrays retain schema order,
    /// and the canonical model contains no dictionaries.
    public static func canonicalData(of itemType: ItemType) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(canonicalRepresentation(of: itemType))
    }

    public static func schemaDigest(of itemType: ItemType) throws -> String {
        SHA256.hash(data: try canonicalData(of: itemType))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalSide(
        _ side: Side,
        ordinals: [UUID: Int]
    ) throws -> CanonicalSide {
        try CanonicalSide(slots: side.slots.map { slot in
            let source: CanonicalSlotSource
            switch slot.source {
            case let .field(id):
                source = .field(ordinal: try ordinal(for: id, in: ordinals))
            case let .literal(value):
                source = .literal(normalized(value))
            }
            return CanonicalSlot(source: source, presentation: slot.presentation)
        })
    }

    private static func canonicalCondition(
        _ condition: SlotCondition,
        ordinals: [UUID: Int]
    ) throws -> CanonicalSlotCondition {
        switch condition {
        case let .fieldNotEmpty(id):
            return .fieldNotEmpty(ordinal: try ordinal(for: id, in: ordinals))
        case let .fieldEmpty(id):
            return .fieldEmpty(ordinal: try ordinal(for: id, in: ordinals))
        case let .all(conditions):
            return .all(try conditions.map { try canonicalCondition($0, ordinals: ordinals) })
        case let .any(conditions):
            return .any(try conditions.map { try canonicalCondition($0, ordinals: ordinals) })
        }
    }

    private static func ordinal(for id: UUID, in ordinals: [UUID: Int]) throws -> Int {
        guard let ordinal = ordinals[id] else {
            throw PortableItemTypeIdentityError.unknownFieldReference(id)
        }
        return ordinal
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }
}

public extension ItemType {
    func portableSchemaDigest() throws -> String {
        try PortableItemTypeIdentity.schemaDigest(of: self)
    }
}
