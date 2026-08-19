import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

struct ItemTypeStudioDraftTests {
    @Test func untouchedNoncanonicalDefinitionRoundTripsExactly() throws {
        let front = FieldDef(id: UUID(), name: " Front ", type: .richText, isRequired: true)
        let back = FieldDef(id: UUID(), name: "Back", type: .text)
        let audio = FieldDef(id: UUID(), name: "Audio", type: .audio)
        let image = FieldDef(id: UUID(), name: "Image", type: .image)
        let components = [
            TemplateComponent(
                id: UUID(),
                region: .label,
                purpose: .supporting,
                source: .literal("  keep exact fixed text  "),
                presentation: Presentation(reveal: .blurred)
            ),
            TemplateComponent(
                id: UUID(),
                region: .secondary,
                purpose: .expectedAnswer,
                source: .field(back.id),
                presentation: Presentation(reveal: .blurred)
            ),
            TemplateComponent(
                id: UUID(),
                region: .primary,
                purpose: .question,
                source: .field(audio.id),
                presentation: Presentation(reveal: .always, media: .autoplay)
            ),
            TemplateComponent(
                id: UUID(),
                region: .media,
                purpose: .supporting,
                source: .field(image.id)
            ),
            TemplateComponent(
                id: UUID(),
                region: .supporting,
                purpose: .supporting,
                source: .field(front.id)
            ),
        ]
        let template = Template(
            id: UUID(),
            name: "Unusual",
            layout: .mediaAside,
            components: components,
            interaction: .choose,
            skill: Skill(input: .audio, output: .selection, operation: .classify),
            generateWhen: .any([
                .fieldNotEmpty(image.id),
                .all([.fieldEmpty(audio.id), .fieldNotEmpty(front.id)]),
            ])
        )
        let original = ItemType(
            id: UUID(),
            name: " Preserve Me ",
            fields: [front, back, audio, image],
            templates: [template]
        )
        try ItemTypeValidation.validate(original)

        let draft = ItemTypeStudioDraft(itemType: original)

        #expect(!draft.isDirty)
        #expect(draft.validationIssues.isEmpty)
        #expect(try draft.candidateItemType() == original)
        #expect(try draft.candidateItemType().templates[0].components.map(\.id) == components.map(\.id))
    }

    @Test func newTypeBeginsWithVisibleFrontBackAndValidBasicSetup() throws {
        var draft = ItemTypeStudioDraft.new(id: UUID())
        #expect(draft.fields.map(\.name) == ["Front", "Back"])
        #expect(draft.cardSetups.count == 1)
        #expect(draft.cardSetups[0].components.count == 2)
        #expect(draft.cardSetups[0].components.map(\.purpose) == [.question, .expectedAnswer])
        #expect(draft.cardSetups[0].interaction == .reveal)
        #expect(!draft.isDirty)

        draft.name = "Vocabulary"
        let candidate = try draft.candidateItemType()
        try ItemTypeValidation.validate(candidate)
        #expect(candidate.templates[0].prompt.slots[0].source == .field(candidate.fields[0].id))
        #expect(candidate.templates[0].answer.slots[0].source == .field(candidate.fields[1].id))
    }

    @Test func fieldMovementPreservesIdentityPersistsOrderAndRefreshesOnlyRecommendations() throws {
        let front = FieldDef(name: "Front", type: .text, isRequired: true)
        let back = FieldDef(name: "Back", type: .text, isRequired: true)
        let notes = FieldDef(name: "Notes", type: .text)
        let storedRoute = Skill(input: .text, output: .text, operation: .recognize)
        let template = Template(
            name: "Basic",
            layout: .split,
            components: [
                TemplateComponent(
                    region: .primary,
                    purpose: .question,
                    source: .field(front.id)
                ),
                TemplateComponent(
                    region: .secondary,
                    purpose: .expectedAnswer,
                    source: .field(back.id),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ],
            interaction: .reveal,
            skill: storedRoute
        )
        var draft = ItemTypeStudioDraft(itemType: ItemType(
            name: "Reordered",
            fields: [front, back, notes],
            templates: [template]
        ))

        let moved = draft.moveField(id: back.id, .up)
        #expect(moved)
        #expect(draft.fields.map(\.id) == [back.id, front.id, notes.id])
        #expect(draft.cardSetups[0].components.map(\.source.fieldID) == [front.id, back.id])
        #expect(draft.cardSetups[0].layout == .split)
        #expect(draft.cardSetups[0].learningRoute == storedRoute)
        #expect(draft.cardSetups[0].recommendation?.learningRoute.operation == .recall)

        let candidate = try draft.candidateItemType()
        #expect(candidate.fields.map(\.id) == [back.id, front.id, notes.id])
        #expect(candidate.templates[0].components.map(\.source) == [
            .field(front.id),
            .field(back.id),
        ])
        #expect(candidate.templates[0].skill == storedRoute)

        let boundaryState = draft
        let movedPastBoundary = draft.moveField(id: back.id, .up)
        let movedMissing = draft.moveField(id: UUID(), .down)
        #expect(!movedPastBoundary)
        #expect(!movedMissing)
        #expect(draft == boundaryState)
    }

    @Test(arguments: CardSetupStarter.allCases)
    func everyApplicableStarterBuildsAValidSetup(starter: CardSetupStarter) throws {
        let fields = [
            ItemTypeFieldDraft(name: "Front", type: .text),
            ItemTypeFieldDraft(name: "Back", type: .text),
            ItemTypeFieldDraft(name: "Picture", type: .image),
            ItemTypeFieldDraft(name: "Sentence", type: .cloze),
        ]
        #expect(starter.isApplicable(to: fields))
        let setup = try starter.makeCardSetup(id: UUID(), fields: fields)
        let itemType = ItemType(
            name: "Starter",
            fields: fields.map(\.fieldDefinition),
            templates: [try setup.template()]
        )

        try ItemTypeValidation.validate(itemType)
        #expect(setup.recommendation != nil)
        #expect(!setup.isLayoutManuallySelected)
        if starter == .audioSubmission {
            #expect(setup.components.allSatisfy { $0.purpose != .expectedAnswer })
            #expect(setup.learningRoute.output == .audio)
        }
        if starter == .visual {
            #expect(setup.availability != nil)
            #expect(setup.components.contains { $0.region == .media })
        }
    }

    @Test func manualLayoutIsStickyAndLearningRecommendationIsExplicit() throws {
        let fields = [
            ItemTypeFieldDraft(name: "Front", type: .text),
            ItemTypeFieldDraft(name: "Back", type: .text),
            ItemTypeFieldDraft(name: "Extra", type: .text),
        ]
        var setup = try CardSetupStarter.basic.makeCardSetup(fields: fields)
        setup.chooseLayout(.split)
        let storedRoute = Skill(input: .diagram, output: .sequence, operation: .apply)
        setup.learningRoute = storedRoute
        setup.components.append(CardSetupComponentDraft(
            source: .field(fields[2].id),
            region: .supporting,
            purpose: .supporting
        ))

        setup.refreshRecommendation(fields: fields)

        #expect(setup.layout == .split)
        #expect(setup.learningRoute == storedRoute)
        #expect(setup.isLayoutManuallySelected)
        #expect(setup.recommendation != nil)

        setup.useRecommendation()
        #expect(setup.layout == .split)
        #expect(setup.learningRoute == setup.recommendation?.learningRoute)
        #expect(setup.isLayoutManuallySelected)
    }

    @Test func persistedEmptyAndWhitespaceFixedTextRoundTripsButNewEmptyInputIsIncomplete() throws {
        let front = FieldDef(name: "Front", type: .text)
        let whitespace = TemplateComponent(
            region: .label,
            purpose: .supporting,
            source: .literal("  \n")
        )
        let empty = TemplateComponent(
            region: .supporting,
            purpose: .supporting,
            source: .literal("")
        )
        let question = TemplateComponent(
            region: .primary,
            purpose: .question,
            source: .field(front.id)
        )
        let answer = TemplateComponent(
            region: .secondary,
            purpose: .expectedAnswer,
            source: .literal("answer"),
            presentation: Presentation(reveal: .hiddenUntilAnswer)
        )
        let original = ItemType(name: "Literals", fields: [front], templates: [Template(
            name: "Card",
            layout: .focus,
            components: [whitespace, empty, question, answer],
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recognize)
        )])
        try ItemTypeValidation.validate(original)

        let draft = ItemTypeStudioDraft(itemType: original)
        #expect(draft.validationIssues.isEmpty)
        #expect(try draft.candidateItemType() == original)

        var newDraft = ItemTypeStudioDraft(itemType: original)
        newDraft.cardSetups[0].components.append(CardSetupComponentDraft(
            source: .fixedText(" \n "),
            region: .supporting,
            purpose: .supporting
        ))
        #expect(!newDraft.validationIssues.isEmpty)
        #expect(throws: ItemTypeStudioDraftError.self) {
            try newDraft.candidateItemType()
        }
    }

    @Test func transientAuthoringMetadataDoesNotMakeTheDraftDirty() throws {
        var draft = ItemTypeStudioDraft.new()
        draft.name = "Transient State"
        let baseline = try draft.candidateItemType()
        draft.markSaved(as: baseline)
        let initialSetup = draft.cardSetups[0]

        draft.cardSetups[0].refreshRecommendation(fields: draft.fields)
        draft.cardSetups[0].chooseLayout(initialSetup.layout)
        #expect(!draft.isDirty)

        let enteredAudio = draft.cardSetups[0].setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(enteredAudio)
        draft.cardSetups[0].interaction = initialSetup.interaction
        draft.cardSetups[0].learningRoute = initialSetup.learningRoute
        draft.cardSetups[0].components = initialSetup.components

        #expect(!draft.isDirty)
        #expect(try draft.candidateItemType() == baseline)
    }

    @Test func emptyAvailabilityGroupsRoundTripExactly() throws {
        let front = FieldDef(name: "Front", type: .text)
        let back = FieldDef(name: "Back", type: .text)
        func template(name: String, condition: SlotCondition) -> Template {
            Template(
                name: name,
                layout: .focus,
                components: [
                    TemplateComponent(
                        region: .primary,
                        purpose: .question,
                        source: .field(front.id)
                    ),
                    TemplateComponent(
                        region: .secondary,
                        purpose: .expectedAnswer,
                        source: .field(back.id),
                        presentation: Presentation(reveal: .hiddenUntilAnswer)
                    ),
                ],
                interaction: .reveal,
                skill: Skill(input: .text, output: .text, operation: .recognize),
                generateWhen: condition
            )
        }
        let original = ItemType(
            name: "Empty Boolean Groups",
            fields: [front, back],
            templates: [
                template(name: "All", condition: .all([])),
                template(name: "Any", condition: .any([])),
                template(name: "Nested", condition: .all([.any([]), .all([])])),
            ]
        )
        try ItemTypeValidation.validate(original)

        let draft = ItemTypeStudioDraft(itemType: original)

        #expect(!draft.isDirty)
        #expect(draft.validationIssues.isEmpty)
        #expect(try draft.candidateItemType() == original)
    }

    @Test func recommendationsRespectEveryAnswerMethodSemantic() {
        let fields = [
            ItemTypeFieldDraft(name: "Question", type: .text),
            ItemTypeFieldDraft(name: "Answer", type: .text),
        ]
        let components = [
            CardSetupComponentDraft(
                source: .field(fields[0].id),
                region: .primary,
                purpose: .question
            ),
            CardSetupComponentDraft(
                source: .field(fields[1].id),
                region: .secondary,
                purpose: .expectedAnswer,
                reveal: .hiddenUntilAnswer
            ),
        ]
        let expected: [(Interaction, Modality, NeoAnkiCore.Operation, CardLayoutID)] = [
            (.reveal, .text, .recognize, .focus),
            (.type, .freeResponse, .recall, .focus),
            (.cloze, .freeResponse, .recall, .focus),
            (.choose, .selection, .classify, .actionStage),
            (.arrange, .sequence, .order, .actionStage),
            (.record, .audio, .reproduce, .actionStage),
            (.audioSubmission, .audio, .reproduce, .actionStage),
        ]

        for (interaction, output, operation, layout) in expected {
            let recommendation = CardSetupRecommendation.make(
                components: components,
                interaction: interaction,
                fields: fields
            )
            #expect(recommendation.layout == layout)
            #expect(recommendation.learningRoute == Skill(
                input: .text,
                output: output,
                operation: operation
            ))
        }
    }

    @Test func refreshingEveryAnswerMethodRecommendationNeverMutatesStoredMetadata() {
        let fields = [
            ItemTypeFieldDraft(name: "Question", type: .text),
            ItemTypeFieldDraft(name: "Answer", type: .text),
        ]
        let storedRoute = Skill(input: .diagram, output: .spatial, operation: .locate)

        for interaction in Interaction.allCases {
            var setup = CardSetupDraft(
                name: "Existing",
                layout: .split,
                interaction: interaction,
                learningRoute: storedRoute,
                components: [
                    CardSetupComponentDraft(
                        source: .field(fields[0].id),
                        region: .primary,
                        purpose: .question
                    ),
                    CardSetupComponentDraft(
                        source: .field(fields[1].id),
                        region: .secondary,
                        purpose: .expectedAnswer,
                        reveal: .hiddenUntilAnswer
                    ),
                ]
            )

            setup.refreshRecommendation(fields: fields)

            #expect(setup.layout == .split)
            #expect(setup.learningRoute == storedRoute)
            #expect(setup.recommendation != nil)
        }
    }

    @Test func existingStoredLearningRouteIsAuthoritative() {
        let frontID = UUID()
        let backID = UUID()
        let route = Skill(input: .video, output: .spatial, operation: .locate)
        let template = Template(
            name: "Existing",
            layout: .focus,
            components: [
                TemplateComponent(region: .primary, purpose: .question, source: .field(frontID)),
                TemplateComponent(
                    region: .secondary,
                    purpose: .expectedAnswer,
                    source: .field(backID),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ],
            interaction: .reveal,
            skill: route
        )
        var setup = CardSetupDraft(template: template)
        let fields = [
            ItemTypeFieldDraft(id: frontID, name: "Front", type: .text),
            ItemTypeFieldDraft(id: backID, name: "Back", type: .text),
        ]

        setup.refreshRecommendation(fields: fields)

        #expect(setup.learningRoute == route)
        #expect(setup.layout == .focus)
        #expect(setup.recommendation?.learningRoute != route)
    }

    @Test func setupDeletionIsReversibleAndFinalSetupIsProtected() throws {
        var draft = ItemTypeStudioDraft.new()
        draft.name = "Two Cards"
        let reverse = try CardSetupStarter.reverse.makeCardSetup(fields: draft.fields)
        draft.cardSetups.append(reverse)

        let removal = draft.removeCardSetupChangeSet(id: reverse.id)
        #expect(removal?.removedCardSetupIDs == [reverse.id])
        #expect(removal?.affectedCardSetupIDs == [reverse.id])
        #expect(draft.cardSetups.count == 1)
        #expect(draft.pendingRemovedCardSetupIDs == [reverse.id])
        let didRemoveFinal = draft.removeCardSetup(id: draft.cardSetups[0].id)
        #expect(!didRemoveFinal)
        let didUndo = draft.undoLastCardSetupRemoval()
        #expect(didUndo)
        #expect(draft.cardSetups.map(\.id).contains(reverse.id))
        #expect(draft.pendingRemovedCardSetupIDs.isEmpty)
        #expect(try draft.candidateItemType().templates.count == 2)
    }

    @Test func fieldRemovalClearsEveryReferenceAndRequiresRepair() throws {
        let frontID = UUID()
        let backID = UUID()
        let template = Template(
            name: "Nested",
            layout: .focus,
            components: [
                TemplateComponent(region: .primary, purpose: .question, source: .field(frontID)),
                TemplateComponent(
                    region: .secondary,
                    purpose: .expectedAnswer,
                    source: .field(backID),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ],
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recognize),
            generateWhen: .all([.fieldNotEmpty(frontID), .any([.fieldEmpty(backID)])])
        )
        let itemType = ItemType(
            name: "Nested",
            fields: [
                FieldDef(id: frontID, name: "Front", type: .text),
                FieldDef(id: backID, name: "Back", type: .text),
            ],
            templates: [template]
        )
        var draft = ItemTypeStudioDraft(itemType: itemType)

        let changes = draft.removeField(id: frontID)

        #expect(changes.removedFieldIDs == [frontID])
        #expect(changes.affectedCardSetupIDs == [template.id])
        #expect(changes.clearedComponentIDs == [template.components[0].id])
        #expect(changes.clearedAvailabilityCardSetupIDs == [template.id])
        #expect(draft.validationIssues.contains {
            $0.target == .component(cardSetupID: template.id, componentID: template.components[0].id)
        })
        #expect(draft.validationIssues.contains { $0.target == .availability(cardSetupID: template.id) })
        #expect(throws: ItemTypeStudioDraftError.self) { try draft.candidateItemType() }
    }

    @Test func fieldTypeChangeReportsAffectedSetupsWithoutNormalizingThem() {
        var draft = ItemTypeStudioDraft.new()
        let frontID = draft.fields[0].id
        let originalSetup = draft.cardSetups[0]

        let changes = draft.changeFieldType(id: frontID, to: .audio)

        #expect(changes.fieldTypeChanges == [
            ItemTypeStudioFieldTypeChange(fieldID: frontID, oldType: .text, newType: .audio),
        ])
        #expect(changes.affectedCardSetupIDs == [originalSetup.id])
        #expect(draft.cardSetups[0] == originalSetup)
    }

    @Test func emptyCardSetupUsesRecipeTargetsInsteadOfGenericSetupFocus() {
        var draft = ItemTypeStudioDraft.new()
        draft.name = "Empty setup"
        let setupID = draft.cardSetups[0].id
        draft.cardSetups[0].components = []

        let issues = draft.validationIssues

        #expect(issues.contains {
            $0.target == .recipe(cardSetupID: setupID, purpose: .question)
        })
        #expect(issues.contains {
            $0.target == .recipe(cardSetupID: setupID, purpose: .expectedAnswer)
        })
        #expect(!issues.contains { $0.target == .cardSetup(setupID) })
        #expect(!issues.contains { $0.target == .itemTypeName })
    }

    @Test func invalidClozeStructureTargetsRecipeOrOffendingComponent() {
        var missingCloze = ItemTypeStudioDraft.new()
        missingCloze.name = "Missing Cloze"
        missingCloze.cardSetups[0].interaction = .cloze
        let missingSetupID = missingCloze.cardSetups[0].id
        #expect(missingCloze.validationIssues.contains {
            $0.target == .recipe(cardSetupID: missingSetupID, purpose: .question)
                && $0.message.contains("Cloze")
        })
        #expect(!missingCloze.validationIssues.contains {
            $0.target == .cardSetup(missingSetupID) && $0.message.contains("Cloze")
        })

        var multipleCloze = ItemTypeStudioDraft.new()
        multipleCloze.name = "Multiple Cloze"
        let first = ItemTypeFieldDraft(name: "First Cloze", type: .cloze)
        let second = ItemTypeFieldDraft(name: "Second Cloze", type: .cloze)
        multipleCloze.fields.append(contentsOf: [first, second])
        let extraQuestion = CardSetupComponentDraft(
            source: .field(second.id),
            region: .supporting,
            purpose: .question,
            reveal: .hiddenUntilAnswer
        )
        multipleCloze.cardSetups[0].components.append(CardSetupComponentDraft(
            source: .field(first.id),
            region: .primary,
            purpose: .question,
            reveal: .hiddenUntilAnswer
        ))
        multipleCloze.cardSetups[0].components.append(extraQuestion)
        multipleCloze.cardSetups[0].interaction = .cloze
        let multipleSetupID = multipleCloze.cardSetups[0].id
        #expect(multipleCloze.validationIssues.contains {
            $0.target == .component(
                cardSetupID: multipleSetupID,
                componentID: extraQuestion.id
            ) && $0.message.contains("Cloze")
        })
        #expect(!multipleCloze.validationIssues.contains {
            $0.target == .cardSetup(multipleSetupID) && $0.message.contains("Cloze")
        })
    }

    @Test func fieldRemovalClearsAudioSubmissionStashedAnswersBeforeReversal() throws {
        var draft = ItemTypeStudioDraft.new()
        draft.name = "Stashed answer repair"
        let setupID = draft.cardSetups[0].id
        let answerID = draft.cardSetups[0].components[1].id
        let removedFieldID = draft.fields[1].id
        let enteredAudio = draft.cardSetups[0].setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(enteredAudio)

        let changes = draft.removeField(id: removedFieldID)

        #expect(changes.affectedCardSetupIDs == [setupID])
        #expect(changes.clearedComponentIDs == [answerID])
        let restoredInteraction = draft.cardSetups[0].setInteraction(.reveal)
        #expect(restoredInteraction)
        let restored = try #require(
            draft.cardSetups[0].components.first { $0.id == answerID }
        )
        #expect(restored.source == .field(nil))
        #expect(draft.validationIssues.contains {
            $0.target == .component(cardSetupID: setupID, componentID: answerID)
        })
        #expect(throws: ItemTypeStudioDraftError.self) {
            try draft.candidateItemType()
        }
    }

    @Test func fieldTypeChangeIncludesAudioSubmissionStashedAnswersInImpact() throws {
        var draft = ItemTypeStudioDraft.new()
        let setupID = draft.cardSetups[0].id
        let answerFieldID = draft.fields[1].id
        let enteredAudio = draft.cardSetups[0].setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(enteredAudio)

        let changes = draft.changeFieldType(id: answerFieldID, to: .number)

        #expect(changes.affectedCardSetupIDs == [setupID])
    }

    @Test func newlyAuthoredFixedTextIsCleanAfterRebaseDespiteLiteralMetadata() throws {
        var draft = ItemTypeStudioDraft.new()
        draft.name = "Fixed text"
        draft.cardSetups[0].components[1].setFixedText("Authored answer")
        let candidate = try draft.candidateItemType()

        draft.rebaseOriginalSnapshot(to: candidate)

        #expect(!draft.isDirty)
        #expect(try draft.candidateItemType() == candidate)
    }

    @Test func explicitlyEditingLegacyWhitespaceLiteralRemovesPreservationExemption() throws {
        let front = FieldDef(name: "Front", type: .text)
        let whitespace = TemplateComponent(
            region: .label,
            purpose: .supporting,
            source: .literal("  ")
        )
        let template = Template(
            name: "Legacy",
            layout: .focus,
            components: [
                whitespace,
                TemplateComponent(
                    region: .primary,
                    purpose: .question,
                    source: .field(front.id)
                ),
                TemplateComponent(
                    region: .secondary,
                    purpose: .expectedAnswer,
                    source: .literal("Answer"),
                    presentation: Presentation(reveal: .hiddenUntilAnswer)
                ),
            ],
            interaction: .reveal,
            skill: Skill(input: .text, output: .text, operation: .recognize)
        )
        var draft = ItemTypeStudioDraft(itemType: ItemType(
            name: "Legacy",
            fields: [front],
            templates: [template]
        ))
        #expect(draft.validationIssues.isEmpty)

        draft.cardSetups[0].components[0].setFixedText("  ")

        #expect(draft.validationIssues.contains {
            $0.target == .component(cardSetupID: template.id, componentID: whitespace.id)
        })
        #expect(throws: ItemTypeStudioDraftError.self) {
            try draft.candidateItemType()
        }
    }

    @Test func mediaBehaviorRestoresToEveryCompatiblePlayableTypeAndClearsOnSave() throws {
        let prompt = FieldDef(name: "Prompt", type: .text)
        let audio = FieldDef(name: "Audio", type: .audio)
        let answer = TemplateComponent(
            region: .secondary,
            purpose: .expectedAnswer,
            source: .field(audio.id),
            presentation: Presentation(
                reveal: .hiddenUntilAnswer,
                media: .autoplay
            )
        )
        let loopingSupport = TemplateComponent(
            region: .supporting,
            purpose: .supporting,
            source: .field(audio.id),
            presentation: Presentation(media: .loop)
        )
        let itemType = ItemType(
            name: "Playback",
            fields: [prompt, audio],
            templates: [Template(
                name: "Listen",
                layout: .focus,
                components: [
                    TemplateComponent(
                        region: .primary,
                        purpose: .question,
                        source: .field(prompt.id)
                    ),
                    answer,
                    loopingSupport,
                ],
                interaction: .reveal,
                skill: Skill(input: .text, output: .audio, operation: .recognize)
            )]
        )
        var draft = ItemTypeStudioDraft(itemType: itemType)
        let enteredAudio = draft.cardSetups[0].setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(enteredAudio)

        _ = draft.changeFieldType(id: audio.id, to: .text)
        _ = draft.changeFieldType(id: audio.id, to: .video)
        let restoredInteraction = draft.cardSetups[0].setInteraction(.reveal)
        #expect(restoredInteraction)
        #expect(draft.cardSetups[0].components.first { $0.id == answer.id }?.mediaBehavior == .autoplay)
        #expect(draft.cardSetups[0].components.first { $0.id == loopingSupport.id }?.mediaBehavior == .loop)

        _ = draft.changeFieldType(id: audio.id, to: .text)
        _ = draft.changeFieldType(id: audio.id, to: .gif)
        #expect(draft.cardSetups[0].components.first { $0.id == answer.id }?.mediaBehavior == .autoplay)
        #expect(draft.cardSetups[0].components.first { $0.id == loopingSupport.id }?.mediaBehavior == .loop)

        _ = draft.changeFieldType(id: audio.id, to: .text)
        _ = draft.changeFieldType(id: audio.id, to: .audio)
        #expect(draft.cardSetups[0].components.first { $0.id == answer.id }?.mediaBehavior == .autoplay)
        #expect(draft.cardSetups[0].components.first { $0.id == loopingSupport.id }?.mediaBehavior == .loop)

        _ = draft.changeFieldType(id: audio.id, to: .text)
        let saved = try draft.candidateItemType()
        draft.markSaved(as: saved)
        _ = draft.changeFieldType(id: audio.id, to: .video)
        #expect(draft.cardSetups[0].components.first { $0.id == answer.id }?.mediaBehavior == .default)
        #expect(draft.cardSetups[0].components.first { $0.id == loopingSupport.id }?.mediaBehavior == .default)
    }

    @Test func mediaBehaviorStashScopesDuplicateComponentIDsToTheirCardSetup() throws {
        let prompt = FieldDef(name: "Prompt", type: .text)
        let media = FieldDef(name: "Media", type: .audio)
        let sharedComponentID = UUID()
        let firstSetupID = UUID()
        let secondSetupID = UUID()
        let firstAnswer = TemplateComponent(
            id: sharedComponentID,
            region: .secondary,
            purpose: .expectedAnswer,
            source: .field(media.id),
            presentation: Presentation(
                reveal: .hiddenUntilAnswer,
                media: .autoplay
            )
        )
        let secondAnswer = TemplateComponent(
            id: sharedComponentID,
            region: .secondary,
            purpose: .expectedAnswer,
            source: .field(media.id),
            presentation: Presentation(
                reveal: .hiddenUntilAnswer,
                media: .loop
            )
        )
        let question = TemplateComponent(
            region: .primary,
            purpose: .question,
            source: .field(prompt.id)
        )
        let itemType = ItemType(
            name: "Duplicate component identities",
            fields: [prompt, media],
            templates: [
                Template(
                    id: firstSetupID,
                    name: "Autoplay",
                    layout: .focus,
                    components: [question, firstAnswer],
                    interaction: .reveal,
                    skill: Skill(input: .text, output: .audio, operation: .recognize)
                ),
                Template(
                    id: secondSetupID,
                    name: "Loop",
                    layout: .focus,
                    components: [question, secondAnswer],
                    interaction: .reveal,
                    skill: Skill(input: .text, output: .audio, operation: .recognize)
                ),
            ]
        )
        try ItemTypeValidation.validate(itemType)
        var draft = ItemTypeStudioDraft(itemType: itemType)
        let secondSetupIndex = try #require(
            draft.cardSetups.firstIndex { $0.id == secondSetupID }
        )
        let enteredAudio = draft.cardSetups[secondSetupIndex].setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(enteredAudio)

        _ = draft.changeFieldType(id: media.id, to: .text)
        #expect(draft.cardSetups.first { $0.id == firstSetupID }?
            .components.first { $0.id == sharedComponentID }?.mediaBehavior == .default)
        _ = draft.changeFieldType(id: media.id, to: .video)
        let leftAudio = draft.cardSetups[secondSetupIndex].setInteraction(.reveal)
        #expect(leftAudio)

        let firstRestored = try #require(
            draft.cardSetups.first { $0.id == firstSetupID }?
                .components.first { $0.id == sharedComponentID }
        )
        let secondRestored = try #require(
            draft.cardSetups.first { $0.id == secondSetupID }?
                .components.first { $0.id == sharedComponentID }
        )
        #expect(firstRestored.mediaBehavior == .autoplay)
        #expect(secondRestored.mediaBehavior == .loop)
        #expect(try draft.candidateItemType().templates.map(\.id) == [firstSetupID, secondSetupID])
    }

    @Test func rebaseDiscardsCommittedMediaStashButPreservesGenuinelyNewerGeneration() throws {
        let media = FieldDef(name: "Media", type: .audio)
        let playable = TemplateComponent(
            region: .primary,
            purpose: .question,
            source: .field(media.id),
            presentation: Presentation(media: .autoplay)
        )
        let itemType = ItemType(
            name: "Rebase playback",
            fields: [media],
            templates: [Template(
                name: "Card",
                layout: .focus,
                components: [
                    playable,
                    TemplateComponent(
                        region: .secondary,
                        purpose: .expectedAnswer,
                        source: .literal("Answer"),
                        presentation: Presentation(reveal: .hiddenUntilAnswer)
                    ),
                ],
                interaction: .reveal,
                skill: Skill(input: .audio, output: .text, operation: .recognize)
            )]
        )

        var committed = ItemTypeStudioDraft(itemType: itemType)
        _ = committed.changeFieldType(id: media.id, to: .text)
        let saved = try committed.candidateItemType()
        var unrelatedNewerEdit = committed
        unrelatedNewerEdit.name = "Newer name"
        unrelatedNewerEdit.rebaseOriginalSnapshot(
            to: saved,
            discardingTransientStateFrom: committed
        )
        _ = unrelatedNewerEdit.changeFieldType(id: media.id, to: .video)
        #expect(unrelatedNewerEdit.cardSetups[0].components.first {
            $0.id == playable.id
        }?.mediaBehavior == .default)
        #expect(unrelatedNewerEdit.name == "Newer name")
        #expect(unrelatedNewerEdit.isDirty)

        var baselineCommit = ItemTypeStudioDraft(itemType: itemType)
        baselineCommit.name = "Committed name"
        let baselineSaved = try baselineCommit.candidateItemType()
        var genuinelyNewer = baselineCommit
        _ = genuinelyNewer.changeFieldType(id: media.id, to: .text)
        genuinelyNewer.rebaseOriginalSnapshot(
            to: baselineSaved,
            discardingTransientStateFrom: baselineCommit
        )
        _ = genuinelyNewer.changeFieldType(id: media.id, to: .video)
        #expect(genuinelyNewer.cardSetups[0].components.first {
            $0.id == playable.id
        }?.mediaBehavior == .autoplay)
    }

    @Test func duplicateFieldIdentityProducesTypedValidationInsteadOfTrapping() {
        var draft = ItemTypeStudioDraft.new()
        draft.name = "Duplicate"
        let duplicate = draft.fields[0]
        draft.fields.append(duplicate)

        #expect(draft.validationIssues.contains {
            $0.target == .field(duplicate.id) && $0.message.contains("identity")
        })
        #expect(throws: ItemTypeStudioDraftError.self) { try draft.candidateItemType() }
    }

    @Test func audioSubmissionRequiresConfirmationAndRestoresAnswersInPlace() throws {
        let fields = [
            ItemTypeFieldDraft(name: "Front", type: .text),
            ItemTypeFieldDraft(name: "Back", type: .text),
        ]
        var setup = try CardSetupStarter.basic.makeCardSetup(fields: fields)
        let original = setup

        let changedWithoutConfirmation = setup.setInteraction(.audioSubmission)
        #expect(!changedWithoutConfirmation)
        #expect(setup == original)
        let changedWithConfirmation = setup.setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(changedWithConfirmation)
        #expect(setup.interaction == .audioSubmission)
        #expect(setup.components.allSatisfy { $0.purpose != .expectedAnswer })
        #expect(setup.learningRoute.output == .audio)
        try ItemTypeValidation.validate(ItemType(
            name: "Audio",
            fields: fields.map(\.fieldDefinition),
            templates: [try setup.template()]
        ))

        let didRestore = setup.setInteraction(.reveal)
        #expect(didRestore)
        #expect(setup == original)
    }

    @Test func rebaseDiscardsCommittedAnswerStashButPreservesGenuinelyNewerGeneration() throws {
        var committed = ItemTypeStudioDraft.new()
        committed.name = "Committed audio conversion"
        let setupID = committed.cardSetups[0].id
        let answerID = committed.cardSetups[0].components[1].id
        let enteredAudio = committed.cardSetups[0].setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(enteredAudio)
        let saved = try committed.candidateItemType()

        var unrelatedNewerEdit = committed
        unrelatedNewerEdit.name = "Unrelated newer name"
        unrelatedNewerEdit.rebaseOriginalSnapshot(
            to: saved,
            discardingTransientStateFrom: committed
        )
        let leftAudioAfterSave = unrelatedNewerEdit.cardSetups[0].setInteraction(.reveal)
        #expect(leftAudioAfterSave)
        #expect(!unrelatedNewerEdit.cardSetups[0].components.contains { $0.id == answerID })
        #expect(unrelatedNewerEdit.validationIssues.contains {
            $0.target == .recipe(cardSetupID: setupID, purpose: .expectedAnswer)
        })

        var baselineCommit = ItemTypeStudioDraft.new()
        baselineCommit.name = "Unrelated committed name"
        let baselineAnswerID = baselineCommit.cardSetups[0].components[1].id
        let baselineSaved = try baselineCommit.candidateItemType()
        var genuinelyNewer = baselineCommit
        let newerEnteredAudio = genuinelyNewer.cardSetups[0].setInteraction(
            .audioSubmission,
            confirmAudioAnswerRemoval: true
        )
        #expect(newerEnteredAudio)
        genuinelyNewer.rebaseOriginalSnapshot(
            to: baselineSaved,
            discardingTransientStateFrom: baselineCommit
        )
        let restoredNewerAnswer = genuinelyNewer.cardSetups[0].setInteraction(.reveal)
        #expect(restoredNewerAnswer)
        #expect(genuinelyNewer.cardSetups[0].components.contains { $0.id == baselineAnswerID })
    }

    @Test func markingSavedResetsDirtyStateAndClearsUndoHistory() throws {
        var draft = ItemTypeStudioDraft.new()
        draft.name = "Saved"
        let reverse = try CardSetupStarter.reverse.makeCardSetup(fields: draft.fields)
        draft.cardSetups.append(reverse)
        let didRemove = draft.removeCardSetup(id: reverse.id)
        #expect(didRemove)
        #expect(draft.isDirty)
        let candidate = try draft.candidateItemType()

        draft.markSaved(as: candidate)

        #expect(!draft.isDirty)
        #expect(draft.originalSnapshot == candidate)
        #expect(draft.pendingRemovedCardSetupIDs.isEmpty)
        let didUndo = draft.undoLastCardSetupRemoval()
        #expect(!didUndo)
    }
}
