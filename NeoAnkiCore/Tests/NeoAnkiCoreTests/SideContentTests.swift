import Foundation
import NeoAnkiCore
import Testing

@Test func sideContentResolvesBasicTemplatePromptAndAnswer() {
    let itemType = BuiltInItemTypes.basic
    let template = itemType.templates[0]
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("France")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Paris")),
        ]
    )

    let prompt = SideContent.values(for: template.prompt, from: item)
    let answer = SideContent.values(for: template.answer, from: item)

    #expect(prompt.count == 1)
    #expect(answer.count == 1)
    #expect(ItemDisplay.plainText(from: prompt[0]) == "France")
    #expect(ItemDisplay.plainText(from: answer[0]) == "Paris")
}

@Test func sideContentSkipsEmptyFieldSlots() {
    let side = Side(slots: [
        Slot(source: .field(BuiltInItemTypes.frontFieldID)),
        Slot(source: .literal("Label:")),
    ])
    let item = Item(
        itemTypeID: BuiltInItemTypes.basic.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .empty),
        ]
    )

    let values = SideContent.values(for: side, from: item)

    #expect(values.count == 1)
    #expect(ItemDisplay.plainText(from: values[0]) == "Label:")
}
