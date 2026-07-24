import Foundation
import NeoAnkiCore

public enum ItemTypeFixtures {
    /// Capitals example from docs/ARCHITECTURE.md §5.
    public static func capitals() -> (
        type: ItemType,
        country: FieldDef,
        capital: FieldDef,
        map: FieldDef
    ) {
        let country = FieldDef(name: "Country", type: .text, isRequired: true)
        let capital = FieldDef(name: "Capital", type: .text, isRequired: true)
        let map = FieldDef(name: "Map", type: .image, isRequired: false)

        let recognize = Template(
            name: "Recognize",
            prompt: Side(slots: [Slot(source: .field(country.id))]),
            answer: Side(slots: [Slot(source: .field(capital.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recognize)
        )
        let produce = Template(
            name: "Produce",
            prompt: Side(slots: [Slot(source: .field(capital.id))]),
            answer: Side(slots: [Slot(source: .field(country.id))]),
            interaction: .type,
            skill: Skill(input: .text, output: .freeResponse, operation: .recall)
        )
        let locate = Template(
            name: "Locate",
            prompt: Side(slots: [Slot(source: .field(map.id))]),
            answer: Side(slots: [Slot(source: .field(country.id))]),
            interaction: .reveal,
            skill: Skill(input: .image, output: .spatial, operation: .locate),
            generateWhen: .fieldNotEmpty(map.id)
        )

        let type = ItemType(
            name: "Capitals",
            fields: [country, capital, map],
            templates: [recognize, produce, locate]
        )
        return (type, country, capital, map)
    }
}

public struct ItemBuilder {
    public var itemTypeID: UUID
    public var fields: [FieldValue] = []
    public var tags: [String] = []
    public var deckID: UUID?

    public init(itemTypeID: UUID) {
        self.itemTypeID = itemTypeID
    }

    public func field(_ field: FieldDef, text: String) -> ItemBuilder {
        var copy = self
        copy.fields.append(FieldValue(fieldID: field.id, value: .text(text)))
        return copy
    }

    public func build() -> Item {
        Item(itemTypeID: itemTypeID, fields: fields, tags: tags, deckID: deckID)
    }
}
