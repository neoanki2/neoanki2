import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

@Suite struct ItemEditorDraftTests {
    private func fixture() -> (Item, ItemType, FieldDef, FieldDef, FieldDef) {
        let plain = FieldDef(name: "Question", type: .text, isRequired: true)
        let rich = FieldDef(name: "Explanation", type: .richText)
        let cloze = FieldDef(name: "Cloze", type: .cloze)
        let type = ItemType(name: "Shared draft", fields: [plain, rich, cloze], templates: [])
        let item = Item(itemTypeID: type.id, fields: [
            .init(fieldID: plain.id, value: .text("Який міст?", lang: "uk")),
            .init(fieldID: rich.id, value: .rich([Span("Source", styles: [.bold], link: "https://example.com")])),
            .init(fieldID: cloze.id, value: .cloze("A 🧠 B", blanks: [.init(group: 7, start: 2, length: 1, hint: "Keep")])),
        ], tags: ["Keep", "Україна"], deckID: UUID())
        return (item, type, plain, rich, cloze)
    }

    @Test func unchangedDraftRoundTripsIdentityMetadataAndEveryValue() throws {
        let (item, type, _, _, _) = fixture()
        let draft = ItemEditorDraft(item: item, itemType: type)
        #expect(!draft.hasChanges)
        #expect(draft.canSave)
        #expect(try draft.item() == item)
    }

    @Test(arguments: [false, true])
    func untouchedOptionalEmptyRepresentationsSurviveNoOpAndOtherFieldEdits(editOtherField: Bool) throws {
        let required = FieldDef(name: "Question", type: .text, isRequired: true)
        let optional = (0..<5).map { FieldDef(name: "Optional \($0)", type: $0 >= 3 ? .richText : .text) }
        let type = ItemType(name: "Empty metadata", fields: [required] + optional, templates: [])
        let values: [ContentValue] = [.text("", lang: "uk"), .empty, .text(" \t", lang: "en"), .rich([]), .rich([Span("", styles: [.bold])])]
        let item = Item(itemTypeID: type.id, fields: [.init(fieldID: required.id, value: .text("Question"))]
            + zip(optional, values).map { .init(fieldID: $0.0.id, value: $0.1) })
        var draft = ItemEditorDraft(item: item, itemType: type)
        if editOtherField { draft.setText("Corrected question", for: required.id) }
        let saved = try draft.item()
        for (field, value) in zip(optional, values) {
            #expect(saved.value(for: field.id) == value)
        }
        #expect(saved.value(for: required.id) == .text(editOtherField ? "Corrected question" : "Question"))
    }

    @Test func requiredEmptyValuesStillFailAndExplicitlyClearedOptionalValuesAreOmitted() throws {
        let (item, type, required, rich, _) = fixture()
        var cleared = ItemEditorDraft(item: item, itemType: type)
        cleared.setValue(.empty, for: rich.id)
        #expect(try cleared.item().value(for: rich.id) == nil)
        var missingRequired = ItemEditorDraft(item: item, itemType: type)
        missingRequired.setText("", for: required.id)
        #expect(throws: DatabaseError.self) { try missingRequired.item() }
    }

    @Test func bothNativeEditorsUseOneMetadataPreservingUnicodeEdit() throws {
        let (item, type, plain, rich, cloze) = fixture()
        var draft = ItemEditorDraft(item: item, itemType: type)
        draft.setText("Виправлено", for: plain.id)
        draft.setText("New A 🧠 B", for: cloze.id)
        #expect(draft.hasChanges)
        let saved = try draft.item()
        #expect(saved.id == item.id && saved.itemTypeID == item.itemTypeID)
        #expect(saved.deckID == item.deckID && saved.tags == item.tags)
        #expect(saved.value(for: plain.id) == .text("Виправлено", lang: "uk"))
        #expect(saved.value(for: rich.id) == item.value(for: rich.id))
        #expect(saved.value(for: cloze.id) == .cloze("New A 🧠 B", blanks: [.init(group: 7, start: 6, length: 1, hint: "Keep")]))
    }

    @Test func dirtyStateIncludesDeckAndRevertingContentRestoresCleanState() {
        let (item, type, plain, _, _) = fixture()
        var draft = ItemEditorDraft(item: item, itemType: type)
        draft.setText("Changed", for: plain.id)
        #expect(draft.hasChanges)
        draft.setText("Який міст?", for: plain.id)
        #expect(!draft.hasChanges)
        draft.deckID = nil
        #expect(draft.hasChanges)
        draft.deckID = item.deckID
        #expect(!draft.hasChanges)
    }

    @Test func clearingAndThenReeditingClozeDoesNotLeaveShadowTextState() throws {
        let (item, type, _, _, cloze) = fixture()
        var draft = ItemEditorDraft(item: item, itemType: type)
        draft.setValue(.empty, for: cloze.id)
        #expect(draft.canSave)
        #expect(try draft.item().value(for: cloze.id) == nil)
        draft.setValue(.cloze("Brain", blanks: [.init(group: 8, start: 0, length: 5)]), for: cloze.id)
        #expect(draft.canSave)
        #expect(try draft.item().value(for: cloze.id) == .cloze("Brain", blanks: [.init(group: 8, start: 0, length: 5)]))
    }

    @Test(arguments: ["none", "overlap", "overflow"])
    func clozeValidationUsesThePersistenceContractWithoutOverflow(scenario: String) {
        let (item, type, _, _, cloze) = fixture()
        var draft = ItemEditorDraft(item: item, itemType: type)
        let blanks: [ClozeSpan]
        switch scenario {
        case "none": blanks = []
        case "overlap": blanks = [.init(group: 1, start: 0, length: 3), .init(group: 2, start: 2, length: 2)]
        default: blanks = [.init(group: 1, start: Int.max, length: Int.max)]
        }
        draft.setValue(.cloze("Alpha", blanks: blanks), for: cloze.id)
        #expect(!draft.canSave)
        #expect(draft.issue(for: cloze.id) != nil)
        #expect(throws: (any Error).self) { try draft.item() }
    }

    @Test func unchangedAlternateTextRepresentationKeepsLanguageAndStyling() throws {
        let plain = FieldDef(name: "Plain", type: .text)
        let rich = FieldDef(name: "Rich", type: .richText)
        let type = ItemType(name: "Representations", fields: [plain, rich], templates: [])
        let item = Item(itemTypeID: type.id, fields: [
            .init(fieldID: plain.id, value: .rich([Span("Styled", styles: [.italic])])),
            .init(fieldID: rich.id, value: .text("Language", lang: "uk")),
        ])
        let draft = ItemEditorDraft(item: item, itemType: type)
        #expect(draft.text(for: plain.id) == "Styled")
        #expect(draft.text(for: rich.id) == "Language")
        #expect(try draft.item() == item)
    }

    @Test func formattedTextFieldsUseStableSpanEditingAndPreserveFormattingOnEdit() throws {
        let field = FieldDef(name: "Question", type: .text)
        let type = ItemType(name: "Formatted text", fields: [field], templates: [])
        let originalSpans = [Span("Kyiv ", styles: [.bold]), Span("bridge", link: "https://example.com/bridge")]
        let item = Item(itemTypeID: type.id, fields: [.init(fieldID: field.id, value: .rich(originalSpans))])
        var draft = ItemEditorDraft(item: item, itemType: type)
        #expect(draft.requiresSpanEditing(for: field.id))

        var editedSpans = originalSpans
        editedSpans[1].text += "?"
        draft.setValue(.rich(editedSpans), for: field.id)
        #expect(try draft.item().value(for: field.id) == .rich(editedSpans))
        draft.setValue(.empty, for: field.id)
        #expect(draft.requiresSpanEditing(for: field.id))
        draft.setValue(.rich([Span("Replacement")]), for: field.id)
        #expect(draft.requiresSpanEditing(for: field.id))
        #expect(try draft.item().value(for: field.id) == .text("Replacement"))
    }

    @Test func ordinaryTextKeepsPlainEditingWhileRichFieldsAndNewFormattingUseSpans() {
        let plain = FieldDef(name: "Plain", type: .text)
        let rich = FieldDef(name: "Rich", type: .richText)
        let type = ItemType(name: "Editor choices", fields: [plain, rich], templates: [])
        let item = Item(itemTypeID: type.id, fields: [.init(fieldID: plain.id, value: .text("Question", lang: "uk"))])
        var draft = ItemEditorDraft(item: item, itemType: type)
        #expect(!draft.requiresSpanEditing(for: plain.id))
        #expect(draft.requiresSpanEditing(for: rich.id))
        draft.setValue(.rich([Span("Question", styles: [.italic])]), for: plain.id)
        #expect(draft.requiresSpanEditing(for: plain.id))
        draft.setValue(.empty, for: plain.id)
        #expect(draft.requiresSpanEditing(for: plain.id))
    }

    @Test(arguments: ["NaN", "inf", "not a number"])
    func invalidNumbersAreRejectedBeforeSave(input: String) {
        let field = FieldDef(name: "Number", type: .number)
        let type = ItemType(name: "Number", fields: [field], templates: [])
        var draft = ItemEditorDraft(item: .init(itemTypeID: type.id, fields: []), itemType: type)
        draft.setText(input, for: field.id)
        #expect(!draft.canSave)
        #expect(throws: (any Error).self) { try draft.item() }
    }
}
