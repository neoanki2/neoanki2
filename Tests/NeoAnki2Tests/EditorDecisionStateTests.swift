import Testing
import NeoAnkiApplication

@testable import NeoAnki2

@Test func unchangedDraftDismissesWithoutConfirmation() {
    let draft = ItemTypeStudioDraft.new()
    #expect(EditorDecisionState.dismissalDecision(initial: draft, current: draft) == .dismiss)
}

@Test func dirtyDraftRequiresDiscardConfirmationForCancelOrEscape() {
    let initial = ItemTypeStudioDraft.new()
    var current = initial
    current.name = "Changed"

    #expect(
        EditorDecisionState.dismissalDecision(initial: initial, current: current)
            == .confirmDiscard
    )
}

@Test func macFieldRemovalPreviewIncludesAudioSubmissionStashedAnswers() throws {
    var draft = ItemTypeStudioDraft.new()
    let setup = try #require(draft.cardSetups.first)
    let removedFieldID = try #require(draft.fields.last?.id)
    let enteredAudioSubmission = draft.cardSetups[0].setInteraction(
        .audioSubmission,
        confirmAudioAnswerRemoval: true
    )
    #expect(enteredAudioSubmission)
    #expect(draft.cardSetups[0].components.allSatisfy {
        $0.source.fieldID != removedFieldID
    })

    #expect(MacItemTypeStudioFieldRemovalPolicy.affectedSetupNames(
        removing: removedFieldID,
        from: draft
    ) == [setup.name])
}

@Test func macStudioDraftBindingAcceptsOnlyItsMountedIdentityAndSnapshot() throws {
    var mounted = ItemTypeStudioDraft.new()
    mounted.name = "Mounted"

    #expect(MacItemTypeStudioDraftBindingPolicy.isSameMountedDraft(mounted, as: mounted))
    #expect(!MacItemTypeStudioDraftBindingPolicy.isSameMountedDraft(nil, as: mounted))
    #expect(!MacItemTypeStudioDraftBindingPolicy.isSameMountedDraft(
        ItemTypeStudioDraft.new(),
        as: mounted
    ))

    let saved = try mounted.candidateItemType()
    var rebased = mounted
    rebased.markSaved(as: saved)
    #expect(rebased.id == mounted.id)
    #expect(!MacItemTypeStudioDraftBindingPolicy.isSameMountedDraft(rebased, as: mounted))
}
