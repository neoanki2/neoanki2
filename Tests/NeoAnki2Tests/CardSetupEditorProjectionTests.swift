import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiSharedUI
import Testing

@Test("Card setup editor projection preserves order and separates noncanonical mappings")
func cardSetupEditorProjectionPreservesLegacyMappings() {
    let front = ItemTypeFieldDraft(name: "Front", type: .text)
    let back = ItemTypeFieldDraft(name: "Back", type: .text)
    let canonicalQuestion = CardSetupComponentDraft(
        source: .field(front.id),
        region: .primary,
        purpose: .question
    )
    let legacySupporting = CardSetupComponentDraft(
        source: .fixedText("Legacy hint"),
        region: .primary,
        purpose: .supporting
    )
    let answer = CardSetupComponentDraft(
        source: .field(back.id),
        region: .secondary,
        purpose: .expectedAnswer,
        reveal: .hiddenUntilAnswer
    )
    let setup = CardSetupDraft(
        name: "Legacy",
        layout: .focus,
        interaction: .reveal,
        learningRoute: Skill(input: .text, output: .text, operation: .recognize),
        components: [canonicalQuestion, legacySupporting, answer]
    )

    let projection = CardSetupEditorProjection(setup: setup, fields: [front, back])

    #expect(projection.resolvedComponents.map(\.id) == setup.components.map(\.id))
    #expect(projection.canonicalComponentIDs == [canonicalQuestion.id, answer.id])
    #expect(projection.additionalComponentIDs == [legacySupporting.id])
    #expect(projection.resolvedComponents.map { component in
        if case let .text(value, _) = component.value { return value }
        return ""
    } == ["Front", "Legacy hint", "Back"])
}

@Test("Editor preview concealment follows purpose even for an unusual region")
func cardSetupEditorProjectionConcealsNoncanonicalAnswer() {
    let field = ItemTypeFieldDraft(name: "Answer", type: .text)
    let unusualAnswer = CardSetupComponentDraft(
        source: .field(field.id),
        region: .media,
        purpose: .expectedAnswer,
        reveal: .hiddenUntilAnswer
    )
    let setup = CardSetupDraft(
        name: "Unusual",
        layout: .mediaAside,
        interaction: .reveal,
        learningRoute: Skill(input: .text, output: .text, operation: .recall),
        components: [unusualAnswer]
    )
    let projection = CardSetupEditorProjection(setup: setup, fields: [field])

    #expect(projection.additionalComponentIDs == [unusualAnswer.id])
    #expect(projection.descriptor.renderedComponents(
        from: projection.resolvedComponents,
        answerRevealed: false
    ).isEmpty)
    #expect(projection.descriptor.renderedComponents(
        from: projection.resolvedComponents,
        answerRevealed: true
    ).map(\.id) == [unusualAnswer.id])
}

@Test("New Studio drafts expose Front, Back, and a fillable Basic setup")
func newStudioDraftFeedsSharedEditor() throws {
    var draft = ItemTypeStudioDraft.new()
    draft.name = "Vocabulary"
    let setup = try #require(draft.cardSetups.first)
    let projection = CardSetupEditorProjection(setup: setup, fields: draft.fields)

    #expect(draft.fields.map(\.name) == ["Front", "Back"])
    #expect(setup.interaction == .reveal)
    #expect(projection.canonicalComponentIDs == Set(setup.components.map(\.id)))
    #expect(projection.descriptor.layout == setup.layout)
    #expect(try draft.candidateItemType().templates.first?.id == setup.id)
}

@Test("Authoring preview follows production reveal semantics for every purpose")
func cardSetupPreviewPresentationIsTruthful() {
    #expect(CardSetupEditorPreviewPolicy.rendering(
        purpose: .question,
        revealMode: .hiddenUntilAnswer,
        fieldType: .text,
        isAnswerRevealed: false
    ) == .concealed)
    #expect(CardSetupEditorPreviewPolicy.rendering(
        purpose: .supporting,
        revealMode: .blurred,
        fieldType: .image,
        isAnswerRevealed: false
    ) == .blurred)
    #expect(CardSetupEditorPreviewPolicy.rendering(
        purpose: .supporting,
        revealMode: .blurred,
        fieldType: .text,
        isAnswerRevealed: false
    ) == .concealed)
    #expect(CardSetupEditorPreviewPolicy.rendering(
        purpose: .question,
        revealMode: .hiddenUntilAnswer,
        fieldType: .cloze,
        isAnswerRevealed: false
    ) == .content)

    // Purpose-based answer concealment remains stronger than malformed legacy
    // presentation metadata.
    #expect(CardSetupEditorPreviewPolicy.rendering(
        purpose: .expectedAnswer,
        revealMode: .always,
        fieldType: .text,
        isAnswerRevealed: false
    ) == .concealed)
    #expect(CardSetupEditorPreviewPolicy.rendering(
        purpose: .expectedAnswer,
        revealMode: .hiddenUntilAnswer,
        fieldType: .text,
        isAnswerRevealed: true
    ) == .content)
}

@Test("Shared mobile visibility projection stays identical to Core study semantics")
func sharedStudyVisibilityParity() {
    let secret = "PRIVATE_ANSWER"
    let values: [ContentValue] = [
        .text(secret, lang: "en"),
        .rich([Span(secret)]),
        .number(42),
        .cloze(secret, blanks: [ClozeSpan(group: 1, start: 0, length: secret.count)]),
        .media(editorMediaRef(kind: .audio, altText: secret)),
        .media(editorMediaRef(kind: .image, altText: secret)),
        .media(editorMediaRef(kind: .gif, altText: secret)),
        .media(editorMediaRef(kind: .video, altText: secret)),
        .empty,
    ]

    for value in values {
        for reveal in RevealMode.allCases {
            for answerRevealed in [false, true] {
                let core = ContentVisibilityPolicy.decision(
                    for: value,
                    revealMode: reveal,
                    isAnswerRevealed: answerRevealed
                )
                let shared = SharedStudyContentVisibilityPolicy.decision(
                    for: value,
                    revealMode: reveal,
                    isAnswerRevealed: answerRevealed
                )
                #expect(shared.rendering == core.rendering)
                #expect(shared.shouldResolveMedia == core.shouldResolveMedia)
                if shared.rendering == .content {
                    #expect(shared.accessibilityLabel == nil)
                } else {
                    #expect(shared.accessibilityLabel?.contains(secret) == false)
                }
            }
        }
    }

    let cloze = values[3]
    #expect(SharedStudyContentVisibilityPolicy.decision(
        for: cloze,
        revealMode: .hiddenUntilAnswer,
        isAnswerRevealed: false
    ).rendering == .content)
    #expect(SharedStudyContentVisibilityPolicy.decision(
        for: values[5],
        revealMode: .blurred,
        isAnswerRevealed: false
    ).rendering == .blurredMedia)
    #expect(SharedStudyContentVisibilityPolicy.decision(
        for: values[4],
        revealMode: .blurred,
        isAnswerRevealed: false
    ).shouldResolveMedia == false)
}

@Test("Reveal controls offer only contextual values and repair legacy values explicitly")
func revealControlPolicyAndRepair() throws {
    #expect(CardSetupRevealControlPolicy.allowedModes(
        purpose: .expectedAnswer,
        fieldType: .text
    ) == [.hiddenUntilAnswer])
    #expect(CardSetupRevealControlPolicy.allowedModes(
        purpose: .expectedAnswer,
        fieldType: .image
    ) == [.hiddenUntilAnswer])
    #expect(CardSetupRevealControlPolicy.allowedModes(
        purpose: .expectedAnswer,
        fieldType: .gif
    ) == [.hiddenUntilAnswer])
    #expect(CardSetupRevealControlPolicy.allowedModes(
        purpose: .supporting,
        fieldType: .text
    ) == [.always, .hiddenUntilAnswer])
    #expect(CardSetupRevealControlPolicy.allowedModes(
        purpose: .supporting,
        fieldType: .gif
    ) == [.always, .hiddenUntilAnswer, .blurred])

    let answerField = ItemTypeFieldDraft(name: "Answer", type: .text)
    let legacyAnswer = CardSetupComponentDraft(
        source: .field(answerField.id),
        region: .secondary,
        purpose: .expectedAnswer,
        reveal: .always
    )
    let legacyBlurredText = CardSetupComponentDraft(
        source: .field(answerField.id),
        region: .supporting,
        purpose: .supporting,
        reveal: .blurred
    )
    let setup = CardSetupDraft(
        name: "Legacy",
        layout: .focus,
        interaction: .reveal,
        learningRoute: Skill(input: .text, output: .text, operation: .recall),
        components: [legacyAnswer, legacyBlurredText]
    )
    var draft = ItemTypeStudioDraft.new()
    draft.fields = [answerField]
    draft.cardSetups = [setup]

    // Merely loading or rejecting another invalid choice remains lossless.
    #expect(!CardSetupEditorReducer.apply(
        .setReveal(componentID: legacyAnswer.id, .always),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(draft.cardSetups[0].components[0].reveal == .always)

    #expect(CardSetupEditorReducer.apply(
        .setReveal(componentID: legacyAnswer.id, .hiddenUntilAnswer),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(draft.cardSetups[0].components[0].reveal == .hiddenUntilAnswer)

    #expect(!CardSetupEditorReducer.apply(
        .setReveal(componentID: legacyBlurredText.id, .blurred),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(draft.cardSetups[0].components[1].reveal == .blurred)
    #expect(CardSetupEditorReducer.apply(
        .setReveal(componentID: legacyBlurredText.id, .always),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(draft.cardSetups[0].components[1].reveal == .always)
}

@Test("Projection derives blurred preview compatibility from the selected field")
func projectionPreviewUsesFieldType() throws {
    let image = ItemTypeFieldDraft(name: "Image", type: .image)
    let component = CardSetupComponentDraft(
        source: .field(image.id),
        region: .media,
        purpose: .supporting,
        reveal: .blurred
    )
    let setup = CardSetupDraft(
        name: "Visual",
        layout: .mediaHero,
        interaction: .reveal,
        learningRoute: Skill(input: .image, output: .text, operation: .recognize),
        components: [component]
    )
    let projection = CardSetupEditorProjection(setup: setup, fields: [image])
    let resolved = try #require(projection.resolvedComponents.first)

    #expect(projection.previewRendering(for: resolved, isAnswerRevealed: false) == .blurred)
    #expect(projection.previewRendering(for: resolved, isAnswerRevealed: true) == .content)
}

@Test("Explicit source and reversible field-type changes repair playback and refresh recommendations")
func reducerNormalizesPlaybackOnExplicitChanges() throws {
    let audio = ItemTypeFieldDraft(name: "Audio", type: .audio)
    let text = ItemTypeFieldDraft(name: "Text", type: .text)
    let legacyText = ItemTypeFieldDraft(name: "Legacy Text", type: .text)
    let component = CardSetupComponentDraft(
        source: .field(audio.id),
        region: .primary,
        purpose: .question,
        mediaBehavior: .autoplay
    )
    let sourceChangeComponent = CardSetupComponentDraft(
        source: .field(audio.id),
        region: .supporting,
        purpose: .supporting,
        mediaBehavior: .loop
    )
    let answer = CardSetupComponentDraft(
        source: .field(text.id),
        region: .secondary,
        purpose: .expectedAnswer,
        reveal: .hiddenUntilAnswer
    )
    let setup = CardSetupDraft(
        name: "Audio",
        layout: .focus,
        interaction: .reveal,
        learningRoute: Skill(input: .audio, output: .text, operation: .recognize),
        components: [component, sourceChangeComponent, answer]
    )
    var draft = ItemTypeStudioDraft.new()
    draft.name = "Playback"
    draft.fields = [audio, text, legacyText]
    draft.cardSetups = [setup]
    let untouchedLegacyComponent = CardSetupComponentDraft(
        source: .field(legacyText.id),
        region: .supporting,
        purpose: .supporting,
        mediaBehavior: .autoplay
    )
    draft.cardSetups[0].components.append(untouchedLegacyComponent)

    #expect(CardSetupEditorReducer.apply(
        .changeSource(componentID: sourceChangeComponent.id, source: .field(text.id)),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(draft.cardSetups[0].components[1].mediaBehavior == .default)

    let storedRoute = draft.cardSetups[0].learningRoute
    let changes = ItemTypeStudioDraftReducer.changeFieldType(
        fieldID: audio.id,
        to: .text,
        in: &draft
    )
    #expect(changes.fieldTypeChanges == [
        ItemTypeStudioFieldTypeChange(fieldID: audio.id, oldType: .audio, newType: .text),
    ])
    #expect(draft.cardSetups[0].components[0].mediaBehavior == .default)
    #expect(draft.cardSetups[0].components[3].mediaBehavior == .autoplay)
    #expect(draft.cardSetups[0].recommendation?.learningRoute.input == .text)
    #expect(draft.cardSetups[0].learningRoute == storedRoute)

    let reversedChanges = ItemTypeStudioDraftReducer.changeFieldType(
        fieldID: audio.id,
        to: .audio,
        in: &draft
    )
    #expect(reversedChanges.affectedCardSetupIDs == [setup.id])
    #expect(draft.cardSetups[0].components[0].mediaBehavior == .autoplay)
    #expect(draft.cardSetups[0].components[1].mediaBehavior == .default)
    #expect(draft.cardSetups[0].recommendation?.learningRoute.input == .audio)
    #expect(draft.cardSetups[0].learningRoute == storedRoute)
}

@Test("Untouched invalid legacy playback remains lossless until explicit repair")
func reducerPreservesUntouchedLegacyPlayback() {
    let text = ItemTypeFieldDraft(name: "Text", type: .text)
    let component = CardSetupComponentDraft(
        source: .field(text.id),
        region: .primary,
        purpose: .question,
        mediaBehavior: .autoplay
    )
    let setup = CardSetupDraft(
        name: "Legacy",
        layout: .focus,
        interaction: .reveal,
        learningRoute: Skill(input: .text, output: .text, operation: .recognize),
        components: [component]
    )
    var draft = ItemTypeStudioDraft.new()
    draft.name = "Legacy"
    draft.fields = [text]
    draft.cardSetups = [setup]

    #expect(draft.cardSetups[0].components[0].mediaBehavior == .autoplay)
    #expect(CardSetupEditorReducer.apply(
        .repairMediaBehavior(component.id),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(draft.cardSetups[0].components[0].mediaBehavior == .default)
}

@Test("Explicit fixed-text editor actions revoke persisted literal preservation")
func reducerExplicitLiteralEditsBecomeIncomplete() throws {
    let persisted = TemplateComponent(
        region: .supporting,
        purpose: .supporting,
        source: .literal("  \n")
    )
    let component = CardSetupComponentDraft(component: persisted)
    let setup = CardSetupDraft(
        name: "Legacy literal",
        layout: .focus,
        interaction: .reveal,
        learningRoute: Skill(input: .text, output: .text, operation: .recognize),
        components: [component]
    )
    var draft = ItemTypeStudioDraft.new()
    draft.cardSetups = [setup]

    #expect(try draft.cardSetups[0].components[0].templateComponent().source == .literal("  \n"))
    #expect(CardSetupEditorReducer.apply(
        .editFixedText(componentID: component.id, value: "  \n"),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(throws: ItemTypeStudioDraftError.self) {
        try draft.cardSetups[0].components[0].templateComponent()
    }

    var sourceDraft = ItemTypeStudioDraft.new()
    sourceDraft.cardSetups = [setup]
    #expect(CardSetupEditorReducer.apply(
        .changeSource(componentID: component.id, source: .fixedText(" \t")),
        to: &sourceDraft,
        cardSetupID: setup.id
    ))
    #expect(throws: ItemTypeStudioDraftError.self) {
        try sourceDraft.cardSetups[0].components[0].templateComponent()
    }
}

@Test("Shared editor reducer wires content lifecycle and canonical movement")
func reducerContentLifecycle() throws {
    var draft = ItemTypeStudioDraft.new()
    let setupID = try #require(draft.cardSetups.first?.id)

    #expect(CardSetupEditorReducer.apply(
        .addComponent(source: .fixedText("First"), hole: .context),
        to: &draft,
        cardSetupID: setupID
    ))
    let firstID = try #require(draft.cardSetups[0].components.last?.id)
    #expect(CardSetupEditorReducer.apply(
        .editFixedText(componentID: firstID, value: "Edited"),
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(CardSetupEditorReducer.apply(
        .addComponent(source: .fixedText("Second"), hole: .context),
        to: &draft,
        cardSetupID: setupID
    ))
    let secondID = try #require(draft.cardSetups[0].components.last?.id)
    #expect(CardSetupEditorReducer.apply(
        .moveComponent(secondID, .earlier),
        to: &draft,
        cardSetupID: setupID
    ))
    let contextIDs = draft.cardSetups[0].components
        .filter { $0.region == .supporting && $0.purpose == .supporting }
        .map(\.id)
    #expect(contextIDs == [secondID, firstID])

    draft.cardSetups[0].components.append(CardSetupComponentDraft(
        source: .fixedText("Legacy"),
        region: .label,
        purpose: .question
    ))
    let legacyID = try #require(draft.cardSetups[0].components.last?.id)
    #expect(CardSetupEditorReducer.apply(
        .canonicalize(componentID: legacyID, hole: .answer),
        to: &draft,
        cardSetupID: setupID
    ))
    let canonicalized = try #require(draft.cardSetups[0].components.first { $0.id == legacyID })
    #expect(canonicalized.region == .secondary)
    #expect(canonicalized.purpose == .expectedAnswer)
    #expect(canonicalized.reveal == .hiddenUntilAnswer)

    #expect(CardSetupEditorReducer.apply(
        .removeComponent(firstID),
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(!draft.cardSetups[0].components.contains { $0.id == firstID })
}

@Test("Additional content edits and reorders without canonicalizing its placement")
func reducerPreservesAdditionalPlacementUntilExplicitMove() throws {
    let replacement = ItemTypeFieldDraft(name: "Replacement", type: .text)
    let first = CardSetupComponentDraft(
        source: .fixedText("First legacy"),
        region: .label,
        purpose: .question
    )
    let second = CardSetupComponentDraft(
        source: .fixedText("Second legacy"),
        region: .label,
        purpose: .expectedAnswer,
        reveal: .hiddenUntilAnswer
    )
    let setup = CardSetupDraft(
        name: "Legacy",
        layout: .focus,
        interaction: .reveal,
        learningRoute: Skill(input: .text, output: .text, operation: .recognize),
        components: [first, second]
    )
    var draft = ItemTypeStudioDraft.new()
    draft.fields.append(replacement)
    draft.cardSetups = [setup]

    #expect(CardSetupEditorReducer.apply(
        .moveAdditionalComponent(second.id, .earlier),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(draft.cardSetups[0].components.map(\.id) == [second.id, first.id])
    #expect(draft.cardSetups[0].components[0].region == .label)
    #expect(draft.cardSetups[0].components[0].purpose == .expectedAnswer)
    #expect(draft.cardSetups[0].components[1].region == .label)
    #expect(draft.cardSetups[0].components[1].purpose == .question)

    #expect(CardSetupEditorReducer.apply(
        .changeSource(componentID: second.id, source: .field(replacement.id)),
        to: &draft,
        cardSetupID: setup.id
    ))
    let edited = try #require(draft.cardSetups[0].components.first { $0.id == second.id })
    #expect(edited.source == .field(replacement.id))
    #expect(edited.region == .label)
    #expect(edited.purpose == .expectedAnswer)

    #expect(CardSetupEditorReducer.apply(
        .removeComponent(first.id),
        to: &draft,
        cardSetupID: setup.id
    ))
    #expect(!draft.cardSetups[0].components.contains { $0.id == first.id })

    #expect(CardSetupEditorReducer.apply(
        .canonicalize(componentID: second.id, hole: .question),
        to: &draft,
        cardSetupID: setup.id
    ))
    let canonical = try #require(draft.cardSetups[0].components.first { $0.id == second.id })
    #expect(canonical.region == .primary)
    #expect(canonical.purpose == .question)
}

@Test("Shared editor reducer keeps layout sticky and supports availability, recommendations, and audio reversal")
func reducerSetupActions() throws {
    var draft = ItemTypeStudioDraft.new()
    let setupID = try #require(draft.cardSetups.first?.id)
    let fieldID = try #require(draft.fields.first?.id)

    #expect(CardSetupEditorReducer.apply(
        .chooseLayout(.split),
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(draft.cardSetups[0].layout == .split)
    #expect(draft.cardSetups[0].isLayoutManuallySelected)

    let availability = CardSetupAvailabilityDraft.any([
        .fieldPresent(fieldID),
        .all([.fieldAbsent(fieldID)]),
    ])
    #expect(CardSetupEditorReducer.apply(
        .setAvailability(availability),
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(draft.cardSetups[0].availability == availability)

    let answerIDs = draft.cardSetups[0].components
        .filter { $0.purpose == .expectedAnswer }
        .map(\.id)
    #expect(!CardSetupEditorReducer.apply(
        .setInteraction(.audioSubmission, confirmAudioAnswerRemoval: false),
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(draft.cardSetups[0].components.contains { answerIDs.contains($0.id) })
    #expect(CardSetupEditorReducer.apply(
        .setInteraction(.audioSubmission, confirmAudioAnswerRemoval: true),
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(!draft.cardSetups[0].components.contains { answerIDs.contains($0.id) })
    #expect(CardSetupEditorReducer.apply(
        .setInteraction(.reveal, confirmAudioAnswerRemoval: false),
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(draft.cardSetups[0].components.filter { answerIDs.contains($0.id) }.map(\.id) == answerIDs)

    let storedRoute = draft.cardSetups[0].learningRoute
    draft.cardSetups[0].refreshRecommendation(fields: draft.fields)
    #expect(draft.cardSetups[0].learningRoute == storedRoute)
    #expect(CardSetupEditorReducer.apply(
        .useRecommendation,
        to: &draft,
        cardSetupID: setupID
    ))
    #expect(draft.cardSetups[0].layout == .split)
    #expect(draft.cardSetups[0].isLayoutManuallySelected)
}

@Test("Simple recommended starters keep optional Advanced customization collapsed")
func advancedDisclosurePolicyIsOptional() throws {
    let draft = ItemTypeStudioDraft.new()
    _ = try #require(draft.cardSetups.first)
    _ = try CardSetupStarter.reverse.makeCardSetup(fields: draft.fields)
    _ = try CardSetupStarter.typeAnswer.makeCardSetup(fields: draft.fields)

    #expect(!CardSetupEditorAdvancedPolicy.startsExpanded)
    #expect(ItemTypeStudioAccessibilityID.advanced == "cardSetupEditor.advanced")
}

@Test("Mobile Cloze projection matches macOS for groups, hints, and malformed spans")
func sharedStudyClozeGroupParity() {
    let text = "alpha beta gamma"
    let blanks = [
        ClozeSpan(group: 1, start: 0, length: 5, hint: "first"),
        ClozeSpan(group: 1, start: 1, length: 3, hint: "overlap"),
        ClozeSpan(group: 2, start: 6, length: 4),
        ClozeSpan(group: 1, start: 999, length: 2, hint: "invalid"),
    ]

    for group in [nil, 1, 2, 999] as [Int?] {
        for revealed in [false, true] {
            #expect(SharedStudyClozePresentation.displayText(
                from: text,
                blanks: blanks,
                isAnswerRevealed: revealed,
                group: group
            ) == ClozeValidation.displayText(
                from: text,
                blanks: blanks,
                revealed: revealed,
                group: group
            ))
        }
    }

    #expect(SharedStudyClozePresentation.displayText(
        from: text,
        blanks: blanks,
        isAnswerRevealed: false,
        group: 1
    ) == "[first] beta gamma")
    #expect(SharedStudyClozePresentation.displayText(
        from: text,
        blanks: blanks,
        isAnswerRevealed: false,
        group: 2
    ) == "alpha […] gamma")
    #expect(SharedStudyClozePresentation.displayText(
        from: text,
        blanks: blanks,
        isAnswerRevealed: true,
        group: 1
    ) == text)
}

@Test("Editor sizing metrics guarantee touch targets and cap nested indentation")
func editorSizingMetrics() {
    #expect(CardSetupEditorLayoutMetrics.minimumTouchTarget == 44)
    #expect(CardSetupEditorLayoutMetrics.maximumAvailabilityIndentation == 16)
    #expect(CardSetupEditorLayoutMetrics.availabilityIndentation(depth: -1) == 0)
    #expect(CardSetupEditorLayoutMetrics.availabilityIndentation(depth: 1) == 8)
    #expect(CardSetupEditorLayoutMetrics.availabilityIndentation(depth: 5) == 16)
    let cumulativeIndentation = (0..<20).reduce(CGFloat.zero) { indentation, parentDepth in
        indentation + CardSetupEditorLayoutMetrics.availabilityIndentationIncrement(
            parentDepth: parentDepth
        )
    }
    #expect(cumulativeIndentation == CardSetupEditorLayoutMetrics.maximumAvailabilityIndentation)
    #expect(CardSetupEditorLayoutMetrics.usesVerticalAvailabilityControls(
        isAccessibilitySize: true,
        availableWidth: 900
    ))
    #expect(CardSetupEditorLayoutMetrics.usesVerticalAvailabilityControls(
        isAccessibilitySize: false,
        availableWidth: 320
    ))
    #expect(!CardSetupEditorLayoutMetrics.usesVerticalAvailabilityControls(
        isAccessibilitySize: false,
        availableWidth: 600
    ))
}

@Test("Mounted editor consumes only its own preexisting validation focus")
func editorInitialFocusRouting() {
    let setupID = UUID()
    let componentID = UUID()
    let requested = ItemTypeStudioValidationTarget.component(
        cardSetupID: setupID,
        componentID: componentID
    )
    #expect(CardSetupEditorFocusPolicy.target(
        for: requested,
        cardSetupID: setupID
    ) == requested)
    #expect(CardSetupEditorFocusPolicy.target(
        for: requested,
        cardSetupID: UUID()
    ) == nil)
    #expect(CardSetupEditorFocusPolicy.target(
        for: .itemTypeName,
        cardSetupID: setupID
    ) == nil)

    let structuralTargets: [ItemTypeStudioValidationTarget] = [
        .answerMethod(cardSetupID: setupID),
        .layout(cardSetupID: setupID),
        .recipe(cardSetupID: setupID, purpose: .question),
        .recipe(cardSetupID: setupID, purpose: .expectedAnswer),
    ]
    for target in structuralTargets {
        #expect(CardSetupEditorFocusPolicy.target(
            for: target,
            cardSetupID: setupID
        ) == target)
        #expect(CardSetupEditorFocusPolicy.target(
            for: target,
            cardSetupID: UUID()
        ) == nil)
        #expect(CardSetupEditorFocusPolicy.disclosures(
            for: target,
            cardSetupID: setupID,
            additionalComponentIDs: []
        ) == .init(showsAdvanced: false, showsAdditionalContent: false))
    }

    #expect(CardSetupEditorFocusPolicy.disclosures(
        for: .availability(cardSetupID: setupID),
        cardSetupID: setupID,
        additionalComponentIDs: []
    ) == .init(showsAdvanced: true, showsAdditionalContent: false))
    #expect(CardSetupEditorFocusPolicy.disclosures(
        for: requested,
        cardSetupID: setupID,
        additionalComponentIDs: [componentID]
    ) == .init(showsAdvanced: false, showsAdditionalContent: true))
    #expect(CardSetupEditorFocusPolicy.disclosures(
        for: requested,
        cardSetupID: setupID,
        additionalComponentIDs: []
    ) == .init(showsAdvanced: false, showsAdditionalContent: false))
}

@Test("Structural validation targets route to recipe, answer method, and layout controls")
func editorStructuralValidationTargets() throws {
    let valid = ItemTypeStudioDraft.new()
    let setupID = try #require(valid.cardSetups.first?.id)

    var missingQuestion = valid
    missingQuestion.cardSetups[0].components.removeAll { $0.purpose == .question }
    #expect(missingQuestion.validationIssues.contains {
        $0.target == .recipe(cardSetupID: setupID, purpose: .question)
    })

    var missingAnswer = valid
    missingAnswer.cardSetups[0].components.removeAll { $0.purpose == .expectedAnswer }
    #expect(missingAnswer.validationIssues.contains {
        $0.target == .recipe(cardSetupID: setupID, purpose: .expectedAnswer)
    })

    var missingMedia = valid
    missingMedia.cardSetups[0].chooseLayout(.mediaAside)
    #expect(missingMedia.validationIssues.contains {
        $0.target == .layout(cardSetupID: setupID)
    })

    var invalidAudio = valid
    invalidAudio.cardSetups[0].interaction = .audioSubmission
    #expect(invalidAudio.validationIssues.contains {
        $0.target == .answerMethod(cardSetupID: setupID)
    })
}

@Test("Studio production controls expose stable Advanced child identifiers")
func editorAdvancedAccessibilityIdentifiers() {
    #expect(ItemTypeStudioAccessibilityID.availability == "cardSetupEditor.availability")
    #expect(ItemTypeStudioAccessibilityID.learningRoute == "cardSetupEditor.learningRoute")
}

private func editorMediaRef(kind: MediaKind, altText: String) -> MediaRef {
    let fileExtension: String = switch kind {
    case .audio: "m4a"
    case .image: "png"
    case .gif: "gif"
    case .video: "mp4"
    }
    return MediaRef(
        kind: kind,
        assetHash: String(repeating: "b", count: 64),
        fileExtension: fileExtension,
        altText: altText
    )
}
