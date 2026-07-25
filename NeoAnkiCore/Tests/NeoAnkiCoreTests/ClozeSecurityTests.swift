import Foundation
import Testing
@testable import NeoAnkiCore

@Test func clozeRenderingIsTotalForMalformedAndUnicodeSpans() {
    let text = "A👩‍👩‍👧‍👦e\u{301}Z"
    let malformed = [
        ClozeSpan(group: 1, start: -1, length: 1),
        ClozeSpan(group: 1, start: text.count + 1, length: 1),
        ClozeSpan(group: 1, start: text.count - 1, length: 2),
        ClozeSpan(group: 1, start: 0, length: -1),
        ClozeSpan(group: 1, start: Int.max, length: Int.max),
        ClozeSpan(group: 1, start: text.count - 1, length: 1, hint: "last"),
    ]

    let rendered = ClozeValidation.displayText(from: text, blanks: malformed, revealed: false)

    #expect(rendered == "A👩‍👩‍👧‍👦e\u{301}[last]")
    #expect(ClozeValidation.displayText(from: text, blanks: malformed, revealed: true) == text)
}

@Test func clozeSanitizeDropsOverlapsDeterministically() {
    let blanks = [
        ClozeSpan(group: 2, start: 1, length: 3),
        ClozeSpan(group: 1, start: 0, length: 2),
        ClozeSpan(group: 3, start: 5, length: 1),
    ]

    #expect(
        ClozeValidation.sanitize(text: "abcdef", blanks: blanks) == [
            ClozeSpan(group: 1, start: 0, length: 2),
            ClozeSpan(group: 3, start: 5, length: 1),
        ]
    )
}

@Test func clozeSpanDecodeRejectsNegativeOffsets() {
    let negativeStart = Data(#"{"group":1,"start":-1,"length":1}"#.utf8)
    let negativeLength = Data(#"{"group":1,"start":0,"length":-1}"#.utf8)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ClozeSpan.self, from: negativeStart)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ClozeSpan.self, from: negativeLength)
    }
}

@Test func optionalClozeCannotBePersistedWithInvalidBlank() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-cloze-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()

    let front = FieldDef(name: "Front", type: .text, isRequired: true)
    let back = FieldDef(name: "Back", type: .text, isRequired: true)
    let optionalCloze = FieldDef(name: "Context", type: .cloze, isRequired: false)
    let template = Template(
        name: "Recall",
        prompt: Side(slots: [Slot(source: .field(front.id))]),
        answer: Side(slots: [Slot(source: .field(back.id))]),
        interaction: .reveal,
        skill: Skill(input: .text, output: .freeResponse, operation: .recall)
    )
    let itemType = ItemType(
        name: "Optional cloze",
        fields: [front, back, optionalCloze],
        templates: [template]
    )
    _ = try await store.createItemType(itemType)

    let item = Item(itemTypeID: itemType.id, fields: [
        FieldValue(fieldID: front.id, value: .text("Question")),
        FieldValue(fieldID: back.id, value: .text("Answer")),
        FieldValue(
            fieldID: optionalCloze.id,
            value: .cloze(
                "short",
                blanks: [ClozeSpan(group: 1, start: 4, length: 2)]
            )
        ),
    ])

    await #expect(throws: ClozeValidationError.blankOutOfBounds) {
        try await store.createItem(item)
    }
}

@Test func itemDisplaySurvivesMalformedPersistedCloze() {
    let value = ContentValue.cloze(
        "safe",
        blanks: [
            ClozeSpan(group: 1, start: 99, length: 1),
            ClozeSpan(group: 1, start: 0, length: 1),
        ]
    )

    #expect(ItemDisplay.plainText(from: value) == "[…]afe")
}
