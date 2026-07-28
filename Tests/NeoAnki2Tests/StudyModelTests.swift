import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeStudyModel(
    scheduler: (any Scheduler)? = nil
) async throws -> (StudyModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL, scheduler: scheduler)
    try await store.bootstrap()
    return (StudyModel(store: store), store)
}

@MainActor
private func makeInteractionModel(
    _ interaction: Interaction,
    answer: ContentValue = .text("one two"),
    missingCheckableAnswer: Bool = false
) async throws -> StudyModel {
    let (model, store) = try await makeStudyModel()
    var itemType = try await store.defaultItemType()
    itemType.templates[0].interaction = interaction
    if interaction == .cloze,
       let frontIndex = itemType.fields.firstIndex(where: { $0.id == BuiltInItemTypes.frontFieldID }) {
        itemType.fields[frontIndex].type = .cloze
    }
    if missingCheckableAnswer {
        itemType.templates[0].answer = Side(slots: [Slot(source: .literal(""))])
    }
    _ = try await store.updateItemType(itemType)
    let prompt: ContentValue = interaction == .cloze
        ? .cloze("Prompt", blanks: [ClozeSpan(group: 0, start: 0, length: 6)])
        : .text("Prompt")
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: prompt),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: answer),
            ]
        )
    )
    await model.startSession()
    return model
}

@Test @MainActor func studyModelStartsScopedSession() async throws {
    let (model, store) = try await makeStudyModel()
    let deck = Deck(name: "Geography")
    _ = try await store.createDeck(deck)
    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
            ],
            deckID: deck.id
        )
    )
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Other")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Card")),
            ]
        )
    )

    await model.startSession(scope: .deck(deck.id, name: "Geography"))

    #expect(model.queue.count == 1)
    #expect(model.scopeLabel == "Geography")
}

@Test @MainActor func studyModelRespectsDeckDailyNewLimit() async throws {
    let (model, store) = try await makeStudyModel()
    let deck = Deck(name: "Geography", newCardsPerDay: 1)
    _ = try await store.createDeck(deck)
    let itemType = try await store.defaultItemType()
    for index in 1 ... 2 {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(
                        fieldID: BuiltInItemTypes.frontFieldID,
                        value: .text("Question \(index)")
                    ),
                    FieldValue(
                        fieldID: BuiltInItemTypes.backFieldID,
                        value: .text("Answer \(index)")
                    ),
                ],
                deckID: deck.id
            )
        )
    }

    await model.startSession(scope: .deck(deck.id, name: deck.name))

    #expect(model.queue.count == 1)
}

@Test @MainActor func studyModelStartsSessionWithDueCards() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.startSession()

    #expect(model.isLoading == false)
    #expect(model.queue.count == 1)
    #expect(model.currentCard != nil)
    #expect(model.isFinished == false)
}

@Test @MainActor func studyModelGradesCardAndFinishesSession() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.startSession()
    model.revealAnswer()
    await model.grade(.good)

    #expect(model.isFinished == true)
    #expect(model.currentCard == nil)

    let dueCount = try await store.dueCount()
    #expect(dueCount == 0)
}

@Test @MainActor func everyInteractionKeyboardPrimaryPathReachesGradingAndCompletion() async throws {
    for interaction in [Interaction.reveal, .type, .choose, .record, .cloze, .arrange] {
        let model = try await makeInteractionModel(interaction)

        switch interaction {
        case .type:
            model.updateTypedAnswer("one two")
        case .choose:
            model.selectChoice(try #require(model.choiceOptions.first))
        case .arrange:
            model.selectArrangementItem(at: 0)
            model.moveSelectedArrangementItem(by: 1)
        case .reveal, .record, .cloze:
            break
        }

        model.performPrimaryAction()
        #expect(model.isAnswerRevealed, "Primary keyboard action should reveal \(interaction)")

        await model.grade(.good)
        #expect(model.isFinished, "\(interaction) should be completable")
    }
}

@Test @MainActor func interactionInputValidationDoesNotSoftLock() async throws {
    let typeModel = try await makeInteractionModel(.type)
    typeModel.performPrimaryAction()

    #expect(typeModel.isAnswerRevealed == false)
    #expect(typeModel.interactionMessage != nil)

    typeModel.revealAnswer()
    #expect(typeModel.isAnswerRevealed)

    let choiceModel = try await makeInteractionModel(.choose)
    choiceModel.performPrimaryAction()
    #expect(choiceModel.isAnswerRevealed == false)
    #expect(choiceModel.interactionMessage != nil)
    choiceModel.revealAnswer()
    #expect(choiceModel.isAnswerRevealed)
}

@Test @MainActor func typedAnswersAreEvaluatedAgainstRenderedAnswer() async throws {
    let correct = try await makeInteractionModel(.type, answer: .text("Paris"))
    correct.updateTypedAnswer("  PARIS! ")
    correct.submitTypedAnswer()
    #expect(correct.isAnswerRevealed)
    #expect(correct.answerEvaluation == .correct)

    let incorrect = try await makeInteractionModel(.type, answer: .text("Paris"))
    incorrect.updateTypedAnswer("London")
    incorrect.submitTypedAnswer()
    #expect(incorrect.isAnswerRevealed)
    #expect(incorrect.answerEvaluation == .incorrect)
    incorrect.updateTypedAnswer("")
    #expect(incorrect.typedAnswer == "London")
    #expect(incorrect.answerEvaluation == .incorrect)
}

@Test @MainActor func missingAnswerRecoversToSelfGradeAndCompletion() async throws {
    let model = try await makeInteractionModel(.type, missingCheckableAnswer: true)

    model.performPrimaryAction()

    #expect(model.isAnswerRevealed)
    #expect(model.answerEvaluation == .unavailable)
    await model.grade(.good)
    #expect(model.isFinished)
}

@Test @MainActor func arrangementKeyboardMovesSelectedItem() async throws {
    let model = try await makeInteractionModel(.arrange, answer: .text("first second third"))
    let initial = model.arrangedItems

    model.selectArrangementItem(at: 0)
    model.moveSelectedArrangementItem(by: 1)

    #expect(model.selectedArrangementIndex == 1)
    #expect(model.arrangedItems != initial)
}

@Test @MainActor func arrangementMoveWithoutSelectionGuidesUserAndIgnoresBadIndices() async throws {
    let model = try await makeInteractionModel(.arrange, answer: .text("first second third"))
    let initial = model.arrangedItems

    // Moving before selecting anything is a no-op that explains what to do.
    model.moveSelectedArrangementItem(by: 1)
    #expect(model.selectedArrangementIndex == nil)
    #expect(model.arrangedItems == initial)
    #expect(model.interactionMessage == "Select an item before moving it.")

    // Selecting an out-of-range position (e.g. Command-9 with fewer items) is ignored.
    model.selectArrangementItem(at: 99)
    #expect(model.selectedArrangementIndex == nil)

    // A selected item cannot be moved past the ends of the list.
    model.selectArrangementItem(at: 0)
    model.moveSelectedArrangementItem(by: -1)
    #expect(model.selectedArrangementIndex == 0)
    #expect(model.arrangedItems == initial)
}

@Test @MainActor func studyModelSkipsUnsupportedCard() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.startSession()
    model.skipCurrentCard()

    #expect(model.isFinished == true)
}

@Test @MainActor func studyModelGradesAllRatings() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()

    for rating in ReviewRating.allCases {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q-\(rating.rawValue)")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
                ]
            )
        )
    }

    await model.startSession()
    #expect(model.queue.count == ReviewRating.allCases.count)

    for rating in ReviewRating.allCases {
        model.revealAnswer()
        await model.grade(rating)
    }

    #expect(model.isFinished == false)
    #expect(model.currentCard != nil)
    #expect(model.queue.count == ReviewRating.allCases.count + 1)
    #expect(model.cardsReviewed == ReviewRating.allCases.count)
}

@Test @MainActor func studyModelEmptyQueueFinishesImmediately() async throws {
    let (model, _) = try await makeStudyModel()

    await model.startSession()

    #expect(model.isFinished == true)
    #expect(model.queue.isEmpty)
    #expect(model.currentCard == nil)
}

@Test @MainActor func studyModelProgressLabelUpdates() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    for i in 1...2 {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q\(i)")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A\(i)")),
                ]
            )
        )
    }

    await model.startSession()
    #expect(model.progressLabel == "Card 1 of 2")

    model.revealAnswer()
    await model.grade(.good)
    #expect(model.progressLabel == "Card 2 of 2")
}

@Test @MainActor func studyModelAgainRatingSchedulesRelearning() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
            ]
        )
    )

    await model.startSession()
    model.revealAnswer()
    await model.grade(.again)

    #expect(model.isFinished == false)
    #expect(model.currentCard?.id == model.queue[0].id)
    #expect(model.queue.count == 2)
    #expect(model.progressLabel == "Card 2 of 2")
    #expect(try await store.dueCount() == 1)
}

@Test @MainActor func studyModelFinishesInitialQueueBeforeRepairRound() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    for index in 1...2 {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(
                        fieldID: BuiltInItemTypes.frontFieldID,
                        value: .text("Q\(index)")
                    ),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
                ]
            )
        )
    }

    await model.startSession()
    let failedCardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.again)

    #expect(model.currentCard?.id != failedCardID)

    model.revealAnswer()
    await model.grade(.good)

    #expect(model.currentCard?.id == failedCardID)
    #expect(model.queue.count == 3)
}

@Test @MainActor func undoAgainRemovesPendingLearningRepeat() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
            ]
        )
    )

    await model.startSession()
    model.revealAnswer()
    await model.grade(.again)
    #expect(model.queue.count == 2)
    #expect(model.currentCard != nil)

    await model.undoLastGrade()

    #expect(model.queue.count == 1)
    #expect(model.currentCard != nil)
    #expect(model.cardsReviewed == 0)
    #expect(try await store.dueCount() == 1)
}

@Test @MainActor func failedCardRepeatsAcrossRepairRoundsUntilRemembered() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
            ]
        )
    )

    await model.startSession()
    let cardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.again)
    #expect(model.currentCard?.id == cardID)
    #expect(model.currentCard?.card.memory.stepIndex == 0)

    model.revealAnswer()
    await model.grade(.again)
    #expect(model.currentCard?.id == cardID)
    #expect(model.currentCard?.card.memory.stepIndex == 1)

    model.revealAnswer()
    await model.grade(.good)

    #expect(model.isFinished)
    #expect(model.cardsReviewed == 3)
    #expect(model.reviewedCardIDs == [cardID])
    #expect(try await store.reviewLogCount(for: cardID) == 3)
}

@Test @MainActor func studyModelUndoLastGradeRestoresCard() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    for i in 1...2 {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q\(i)")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A\(i)")),
                ]
            )
        )
    }

    await model.startSession()
    model.revealAnswer()
    await model.grade(.good)

    #expect(model.canUndoLastGrade)
    #expect(model.progressLabel == "Card 2 of 2")

    await model.undoLastGrade()

    #expect(model.canUndoLastGrade == false)
    #expect(model.isAnswerRevealed)
    #expect(model.progressLabel == "Card 1 of 2")
    #expect(try await store.rawReviewLogCount(for: model.queue[0].id) == 1)
    #expect(try await store.activeReviewLogCount(for: model.queue[0].id) == 0)
}

@Test @MainActor func studyModelRejectsConcurrentGrades() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    for i in 1...2 {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q\(i)")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A\(i)")),
                ]
            )
        )
    }

    await model.startSession()
    let gradedCardID = try #require(model.currentCard?.id)
    model.revealAnswer()

    async let firstGrade: Void = model.grade(.good)
    async let secondGrade: Void = model.grade(.easy)
    _ = await (firstGrade, secondGrade)

    #expect(model.index == 1)
    #expect(model.currentCard?.id != gradedCardID)
    #expect(try await store.reviewLogCount(for: gradedCardID) == 1)
}

@Test @MainActor func studyModelRevealsGradesAndAdvancesClozeCard() async throws {
    let (model, store) = try await makeStudyModel()
    let clozeField = FieldDef(name: "Sentence", type: .cloze, isRequired: true)
    let clozeTemplate = Template(
        name: "Cloze",
        prompt: Side(slots: [
            Slot(
                source: .field(clozeField.id),
                presentation: Presentation(reveal: .hiddenUntilAnswer)
            ),
        ]),
        answer: Side(slots: [Slot(source: .field(clozeField.id))]),
        interaction: .cloze,
        skill: Skill(input: .text, output: .freeResponse, operation: .recall)
    )
    let clozeType = ItemType(
        name: "Cloze",
        fields: [clozeField],
        templates: [clozeTemplate]
    )
    _ = try await store.createItemType(clozeType)
    _ = try await store.createItem(
        Item(
            itemTypeID: clozeType.id,
            fields: [
                FieldValue(
                    fieldID: clozeField.id,
                    value: .cloze(
                        "The capital is Paris.",
                        blanks: [ClozeSpan(group: 1, start: 15, length: 5)]
                    )
                ),
            ]
        )
    )

    await model.startSession()
    #expect(model.currentCard?.template.interaction == .cloze)

    model.revealAnswer()
    #expect(model.isAnswerRevealed)
    await model.grade(.good)

    #expect(model.isFinished)
    #expect(model.index == 1)
    #expect(try await store.reviewLogCount(for: model.queue[0].id) == 1)
}

@Test @MainActor func studyModelUndoAfterLastCardRestoresFinishedSession() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
            ]
        )
    )

    await model.startSession()
    let cardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.good)
    #expect(model.isFinished)
    #expect(model.canUndoLastGrade)

    await model.undoLastGrade()

    #expect(model.isFinished == false)
    #expect(model.currentCard?.id == cardID)
    #expect(model.isAnswerRevealed)
    #expect(model.index == 0)
    #expect(try await store.reviewLogCount(for: cardID) == 0)
}

@Test @MainActor func studyModelDiscardsDeletedCardAndContinuesSession() async throws {
    let (model, store) = try await makeStudyModel()
    let itemType = try await store.defaultItemType()
    for i in 1...2 {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q\(i)")),
                    FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A\(i)")),
                ]
            )
        )
    }

    await model.startSession()
    let deletedCard = try #require(model.currentCard)
    #expect(try await store.deleteItem(id: deletedCard.item.id))

    model.revealAnswer()
    await model.grade(.good)

    #expect(model.errorMessage == nil)
    #expect(model.isFinished == false)
    #expect(model.queue.count == 1)
    #expect(model.currentCard?.id != deletedCard.id)
    #expect(model.isAnswerRevealed == false)
}

@Test @MainActor func itemsModelLoadsDueCount() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    let mediaStore = await store.media
    let model = ItemsModel(store: store, mediaStore: mediaStore)
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.load()

    #expect(model.dueCount == 1)
}
