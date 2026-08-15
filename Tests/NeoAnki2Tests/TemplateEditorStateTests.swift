import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

private let textField = FieldDef(name: "Front", type: .text)
private let answerField = FieldDef(name: "Back", type: .richText)
private let audioField = FieldDef(name: "Audio", type: .audio)
private let clozeField = FieldDef(name: "Sentence", type: .cloze)

private var builderItemType: ItemType {
    ItemType(
        name: "Builder Test",
        fields: [textField, answerField, audioField, clozeField],
        templates: []
    )
}

@Test @MainActor func newTemplateBuilderStartsWithBlankDropZones() {
    let state = TemplateEditorState(itemType: builderItemType)
    #expect(state.draft.promptSlots.isEmpty)
    #expect(state.draft.answerSlots.isEmpty)
    #expect(state.selection == nil)
    #expect(state.previewPhase == .beforeAnswer)
}

@Test @MainActor func builderInsertsFieldsAndLiteralText() {
    let state = TemplateEditorState(itemType: builderItemType)
    state.addField(textField.id, to: .prompt)
    state.addLiteral(to: .answer)
    #expect(state.draft.promptSlots.first?.fieldID == textField.id)
    #expect(state.draft.answerSlots.first?.sourceKind == .literal)
}

@Test @MainActor func builderDuplicatesWithNewIdentityAndPreservesPresentation() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    state.addField(audioField.id, to: .prompt)
    let original = try #require(state.draft.promptSlots.first)
    state.updateSlot(on: .prompt, id: original.id) {
        $0.reveal = .blurred
        $0.media = .autoplay
    }
    state.duplicateSlot(on: .prompt, id: original.id)
    let duplicate = try #require(state.draft.promptSlots.last)
    #expect(duplicate.id != original.id)
    #expect(duplicate.fieldID == original.fieldID)
    #expect(duplicate.reveal == .blurred)
    #expect(duplicate.media == .autoplay)
}

@Test @MainActor func builderReordersRemovesAndRecoversSelection() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    state.addField(textField.id, to: .prompt)
    state.addField(answerField.id, to: .prompt)
    let firstID = try #require(state.draft.promptSlots.first?.id)
    let secondID = try #require(state.draft.promptSlots.last?.id)
    state.moveSlot(on: .prompt, id: secondID, by: -1)
    #expect(state.draft.promptSlots.first?.id == secondID)
    state.selection = .slot(side: .prompt, id: secondID)
    state.removeSlot(on: .prompt, id: secondID)
    #expect(state.selection == .slot(side: .prompt, id: firstID))
    state.removeSlot(on: .prompt, id: firstID)
    #expect(state.selection == nil)
}

@Test @MainActor func dragPayloadMovesBlocksAcrossSides() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    state.addField(textField.id, to: .prompt)
    let id = try #require(state.draft.promptSlots.first?.id)
    let accepted = state.accept(
        .init(source: .slot(side: .prompt, id: id)),
        on: .answer
    )
    #expect(accepted)
    #expect(state.draft.promptSlots.isEmpty)
    #expect(state.draft.answerSlots.first?.id == id)
    #expect(state.selection == .slot(side: .answer, id: id))
}

@Test @MainActor func dragPayloadCreatesIngredientsAndReordersOnOneSide() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    #expect(state.accept(.init(source: .field(textField.id)), on: .prompt))
    #expect(state.accept(.init(source: .field(answerField.id)), on: .prompt))
    let firstID = try #require(state.draft.promptSlots.first?.id)
    #expect(state.accept(
        .init(source: .slot(side: .prompt, id: firstID)),
        on: .prompt,
        at: 2
    ))
    #expect(state.draft.promptSlots.last?.id == firstID)
}

@Test @MainActor func unsupportedMediaResetsWhenFieldChanges() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    state.addField(audioField.id, to: .prompt)
    let id = try #require(state.draft.promptSlots.first?.id)
    state.updateSlot(on: .prompt, id: id) { $0.media = .loop }
    state.setField(textField.id, on: .prompt, id: id)
    #expect(state.draft.promptSlots.first?.media == .default)
}

@Test @MainActor func clozeDefaultsAndCompositionAreValidated() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    state.requestInteraction(.cloze)
    state.addField(clozeField.id, to: .prompt)
    state.addField(answerField.id, to: .answer)
    state.draft.name = "Cloze"
    #expect(state.draft.promptSlots.first?.reveal == .hiddenUntilAnswer)
    #expect(state.validate())
    state.addField(clozeField.id, to: .prompt)
    #expect(!state.validate())
    #expect(state.validationIssues.contains { $0.target == .side(.prompt) })
}

@Test @MainActor func audioSubmissionStashesAndRestoresAnswer() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    state.addField(answerField.id, to: .answer)
    let answerID = try #require(state.draft.answerSlots.first?.id)
    state.requestInteraction(.audioSubmission)
    #expect(state.pendingInteraction == .audioSubmission)
    state.confirmPendingInteraction()
    #expect(state.draft.answerSlots.isEmpty)
    #expect(state.draft.skill.output == .audio)
    #expect(!state.accept(.init(source: .literal), on: .answer))
    state.requestInteraction(.reveal)
    #expect(state.draft.answerSlots.first?.id == answerID)
}

@Test @MainActor func validationReportsEveryTargetInOrder() throws {
    let state = TemplateEditorState(itemType: builderItemType)
    state.addLiteral(to: .prompt)
    state.draft.generateWhen = .fieldNotEmpty(nil)
    #expect(!state.validate())
    #expect(state.validationIssues.map(\.target) == [
        .name,
        .slot(side: .prompt, id: state.draft.promptSlots[0].id),
        .side(.answer),
        .generation,
    ])
}

@Test @MainActor func previewFixturesCoverEveryFieldTypeDeterministically() {
    for type in FieldType.allCases {
        let field = FieldDef(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Sample", type: type)
        #expect(TemplatePreviewFixture.value(for: field) == TemplatePreviewFixture.value(for: field))
    }
    #expect(TemplatePreviewFixture.sides(for: .beforeAnswer, interaction: .reveal) == [.prompt])
    #expect(TemplatePreviewFixture.sides(for: .afterAnswer, interaction: .reveal) == [.prompt, .answer])
    #expect(TemplatePreviewFixture.sides(for: .afterAnswer, interaction: .audioSubmission) == [.prompt])
    #expect(!TemplatePreviewFixture.isAnswerRevealed(for: .beforeAnswer))
    #expect(TemplatePreviewFixture.isAnswerRevealed(for: .afterAnswer))
}
