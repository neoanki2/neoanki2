import Foundation
import NeoAnkiApplication
import NeoAnkiCore

#if os(iOS)
enum MobileFitStudyAreaUITestFixture {
    static func seedIfRequested(library: any LibraryRepository) async throws {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-NeoAnkiUITestingReset"),
              process.environment["NEOANKI_TEST_SCENARIO"] == "fit-study-area"
        else { return }

        let character = FieldDef(name: "Character", type: .text, isRequired: true)
        let keyword = FieldDef(name: "Keyword", type: .text, isRequired: true)
        let mnemonic = FieldDef(name: "Mnemonic", type: .text)
        let notes = FieldDef(name: "Notes", type: .text)
        let template = Template(
            name: "Character → keyword",
            layout: .focus,
            components: [
                TemplateComponent(region: .primary, purpose: .question, source: .field(character.id)),
                TemplateComponent(region: .secondary, purpose: .expectedAnswer, source: .field(keyword.id),
                                  presentation: Presentation(reveal: .hiddenUntilAnswer)),
                TemplateComponent(region: .supporting, purpose: .supporting, source: .field(mnemonic.id),
                                  presentation: Presentation(reveal: .hiddenUntilAnswer)),
                TemplateComponent(region: .supporting, purpose: .supporting, source: .field(notes.id),
                                  presentation: Presentation(reveal: .hiddenUntilAnswer)),
            ],
            interaction: .reveal,
            skill: Skill(input: .image, output: .text, operation: .recall),
            fitStudyArea: true
        )
        let itemType = ItemType(
            name: "Kanji Academy",
            fields: [character, keyword, mnemonic, notes],
            templates: [template]
        )
        _ = try await library.createItemType(itemType)
        _ = try await library.createItem(Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: character.id, value: .text("日")),
                FieldValue(fieldID: keyword.id, value: .text("day; sun")),
                FieldValue(fieldID: mnemonic.id, value: .text("The sun crossing the horizon.")),
                FieldValue(fieldID: notes.id, value: .text("Read as nichi or jitsu.")),
            ]
        ))
    }
}
#endif
