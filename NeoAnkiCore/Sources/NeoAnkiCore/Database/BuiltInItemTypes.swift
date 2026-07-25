import Foundation

/// Neutral starter item types offered on first run. They are ordinary,
/// user-deletable item types after the one-time seed; stable UUIDs only make
/// first-run setup deterministic.
public enum BuiltInItemTypes {
    public static let basicID = UUID(uuidString: "A2000001-0000-4000-8000-000000000001")!
    public static let frontFieldID = UUID(uuidString: "A2000001-0001-4000-8000-000000000001")!
    public static let backFieldID = UUID(uuidString: "A2000001-0002-4000-8000-000000000001")!
    public static let clozeID = UUID(uuidString: "A2000002-0000-4000-8000-000000000001")!
    public static let clozeTextFieldID = UUID(uuidString: "A2000002-0001-4000-8000-000000000001")!
    public static let clozeContextFieldID = UUID(uuidString: "A2000002-0002-4000-8000-000000000001")!
    public static let clozeTemplateID = UUID(uuidString: "A2000002-0003-4000-8000-000000000001")!

    /// Two text fields and one reveal template — the smallest useful item type.
    public static let basic: ItemType = {
        let front = FieldDef(
            id: frontFieldID,
            name: "Front",
            type: .text,
            isRequired: true
        )
        let back = FieldDef(
            id: backFieldID,
            name: "Back",
            type: .text,
            isRequired: true
        )
        let card = Template(
            name: "Card",
            prompt: Side(slots: [Slot(source: .field(front.id))]),
            answer: Side(slots: [Slot(source: .field(back.id))]),
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recognize)
        )

        return ItemType(
            id: basicID,
            name: "Basic",
            fields: [front, back],
            templates: [card]
        )
    }()

    /// A ready-to-use structured cloze type. Prompt answers are hidden by
    /// default, and each distinct blank group generates its own card.
    public static let cloze: ItemType = {
        let text = FieldDef(
            id: clozeTextFieldID,
            name: "Text",
            type: .cloze,
            isRequired: true
        )
        let context = FieldDef(
            id: clozeContextFieldID,
            name: "Context",
            type: .richText,
            isRequired: false
        )
        let card = Template(
            id: clozeTemplateID,
            name: "Cloze",
            prompt: Side(slots: [
                Slot(
                    source: .field(text.id),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
                Slot(source: .field(context.id)),
            ]),
            answer: Side(slots: [Slot(source: .field(text.id))]),
            interaction: .cloze,
            skill: Skill(input: .text, output: .freeResponse, operation: .recall)
        )
        return ItemType(
            id: clozeID,
            name: "Cloze",
            fields: [text, context],
            templates: [card]
        )
    }()

    public static let all: [ItemType] = [basic, cloze]

    public static func isBuiltIn(_ id: UUID) -> Bool {
        id == basicID || id == clozeID
    }
}
