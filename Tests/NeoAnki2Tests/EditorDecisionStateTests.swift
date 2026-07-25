import Testing

@testable import NeoAnki2

@Test func unchangedDraftDismissesWithoutConfirmation() {
    let draft = ItemTypeDraft.new
    #expect(EditorDecisionState.dismissalDecision(initial: draft, current: draft) == .dismiss)
}

@Test func dirtyDraftRequiresDiscardConfirmationForCancelOrEscape() {
    let initial = ItemTypeDraft.new
    var current = initial
    current.name = "Changed"

    #expect(
        EditorDecisionState.dismissalDecision(initial: initial, current: current)
            == .confirmDiscard
    )
}

@Test func existingTemplateDeletionRequiresConfirmation() {
    #expect(EditorDecisionState.requiresTemplateDeletionConfirmation(templateExists: true))
    #expect(!EditorDecisionState.requiresTemplateDeletionConfirmation(templateExists: false))
}
