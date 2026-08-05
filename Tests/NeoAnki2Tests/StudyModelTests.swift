import Foundation
import NeoAnkiCore
import SQLite3
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

private actor StudyQueueLoadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor StudyQueueGateProbe {
    private(set) var invocationCount = 0

    func record() {
        invocationCount += 1
    }
}

private actor FirstStudyQueueLoadGate {
    private var invocationCount = 0
    private var firstWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        invocationCount += 1
        guard invocationCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstWaiter = continuation
        }
    }

    func releaseFirst() {
        firstWaiter?.resume()
        firstWaiter = nil
    }
}

@MainActor
private func waitForProgressiveStudyHead(_ model: StudyModel) async throws {
    for _ in 0..<10_000 {
        if model.isPreparingQueue, model.currentCard != nil, !model.isLoading {
            return
        }
        await Task.yield()
    }
    throw DatabaseError.queryFailed("Timed out waiting for the progressive study head.")
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

@Test @MainActor func studyModelPublishesExactHeadBeforeCompletingQueue() async throws {
    let (_, store) = try await makeStudyModel()
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
                    FieldValue(
                        fieldID: BuiltInItemTypes.backFieldID,
                        value: .text("A\(index)")
                    ),
                ]
            )
        )
    }
    let expected = try await store.fetchDueCards()
    let gate = StudyQueueLoadGate()
    let model = StudyModel(
        store: store,
        remainingQueueLoadGate: { await gate.wait() }
    )

    let startTask = Task { await model.startSession() }
    try await waitForProgressiveStudyHead(model)

    #expect(model.queue.map(\.id) == [expected[0].id])
    #expect(model.progressLabel == "Card 1 of 2")
    #expect(model.isFinished == false)
    model.revealAnswer()
    #expect(model.isAnswerRevealed)

    await model.grade(.good)
    model.skipCurrentCard()
    #expect(model.index == 0)
    #expect(model.cardsReviewed == 0)
    #expect(try await store.reviewLogCount(for: expected[0].id) == 0)

    await gate.open()
    await startTask.value

    #expect(model.isPreparingQueue == false)
    #expect(model.queue.map(\.id) == expected.map(\.id))
    #expect(model.progressLabel == "Card 1 of 2")
    #expect(model.isAnswerRevealed)
}

@Test @MainActor func corruptItemTypeUsesAtomicQueueFallback() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-corrupt-type-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
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
    var handle: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path(percentEncoded: false), &handle) == SQLITE_OK)
    let corruptTypeSQL = """
        UPDATE item_types
        SET definition = X'7b2262726f6b656e223a747275657d'
        WHERE id = '\(itemType.id.uuidString)';
        """
    #expect(sqlite3_exec(handle, corruptTypeSQL, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let probe = StudyQueueGateProbe()
    let model = StudyModel(
        store: store,
        remainingQueueLoadGate: { await probe.record() }
    )

    await model.startSession()

    #expect(await probe.invocationCount == 0)
    #expect(model.isPreparingQueue == false)
    #expect(model.queue.isEmpty)
    #expect(model.isFinished)
    #expect(model.didFailToLoad == false)
}

@Test @MainActor func newerStudyStartSupersedesPendingProgressiveLoad() async throws {
    let (_, store) = try await makeStudyModel()
    let firstDeck = Deck(name: "First")
    let secondDeck = Deck(name: "Second")
    _ = try await store.createDeck(firstDeck)
    _ = try await store.createDeck(secondDeck)
    let itemType = try await store.defaultItemType()
    for (prompt, deckID) in [("First card", firstDeck.id), ("Second card", secondDeck.id)] {
        _ = try await store.createItem(
            Item(
                itemTypeID: itemType.id,
                fields: [
                    FieldValue(
                        fieldID: BuiltInItemTypes.frontFieldID,
                        value: .text(prompt)
                    ),
                    FieldValue(
                        fieldID: BuiltInItemTypes.backFieldID,
                        value: .text("Answer")
                    ),
                ],
                deckID: deckID
            )
        )
    }
    let gate = FirstStudyQueueLoadGate()
    let model = StudyModel(
        store: store,
        remainingQueueLoadGate: { await gate.wait() }
    )
    let firstStart = Task { await model.startSession() }
    try await waitForProgressiveStudyHead(model)

    let secondScope = StudyScope.deck(secondDeck.id, name: secondDeck.name)
    await model.startSession(scope: secondScope)
    let secondQueue = model.queue
    await gate.releaseFirst()
    await firstStart.value

    #expect(model.scopeLabel == secondDeck.name)
    #expect(model.queue == secondQueue)
    #expect(model.queue.count == 1)
    #expect(model.queue.first?.item.deckID == secondDeck.id)
    #expect(model.isPreparingQueue == false)
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

@Test @MainActor func textOnlyRecordingCardStatesThatReferenceAudioIsUnavailable() async throws {
    let model = try await makeInteractionModel(.record)

    model.performPrimaryAction()

    #expect(model.isAnswerRevealed)
    #expect(
        model.interactionMessage
            == "No reference audio is available for this card. Replay your recording and compare it with the written answer."
    )
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

@Test @MainActor func undoRepeatedGradeKeepsEarlierReviewedMembership() async throws {
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
    let cardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.again)
    model.revealAnswer()
    await model.grade(.again)

    #expect(model.cardsReviewed == 2)
    #expect(model.reviewedCardIDs == [cardID])
    #expect(model.reviewedItemIDs == [item.id])

    await model.undoLastGrade()

    #expect(model.cardsReviewed == 1)
    #expect(model.reviewedCardIDs == [cardID])
    #expect(model.reviewedItemIDs == [item.id])
    #expect(model.currentCard?.id == cardID)
    #expect(model.isAnswerRevealed)
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

@Test @MainActor func studyModelReloadShowsEditedContentOnEveryQueuedCardOfThatItem() async throws {
    let (model, store) = try await makeStudyModel()
    var itemType = try await store.defaultItemType()
    itemType.templates[0].interaction = .cloze
    let frontIndex = try #require(
        itemType.fields.firstIndex(where: { $0.id == BuiltInItemTypes.frontFieldID })
    )
    itemType.fields[frontIndex].type = .cloze
    _ = try await store.updateItemType(itemType)
    _ = try await store.createItem(
        Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(
                    fieldID: BuiltInItemTypes.frontFieldID,
                    value: .cloze(
                        "Alpha Beta",
                        blanks: [
                            ClozeSpan(group: 0, start: 0, length: 5),
                            ClozeSpan(group: 1, start: 6, length: 4),
                        ]
                    )
                ),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Contex")),
            ]
        )
    )

    await model.startSession()
    #expect(model.queue.count == 2)

    var edited = try #require(model.currentCard?.item)
    let backIndex = try #require(
        edited.fields.firstIndex(where: { $0.fieldID == BuiltInItemTypes.backFieldID })
    )
    edited.fields[backIndex].value = .text("Context, with the typo fixed")
    _ = try await store.updateItem(edited)

    await model.reloadCurrentItem()

    #expect(model.errorMessage == nil)
    #expect(model.queue.count == 2)
    for card in model.queue {
        #expect(card.item.value(for: BuiltInItemTypes.backFieldID) == .text("Context, with the typo fixed"))
    }
}

@Test @MainActor func studyModelReloadRederivesInteractionBeforeReveal() async throws {
    let model = try await makeInteractionModel(.choose, answer: .text("Pariss"))
    #expect(model.choiceOptions.contains("Pariss"))

    var edited = try #require(model.currentCard?.item)
    let backIndex = try #require(
        edited.fields.firstIndex(where: { $0.fieldID == BuiltInItemTypes.backFieldID })
    )
    edited.fields[backIndex].value = .text("Paris")
    _ = try await model.store.updateItem(edited)

    await model.reloadCurrentItem()

    #expect(model.choiceOptions.contains("Paris"))
    #expect(model.choiceOptions.contains("Pariss") == false)
    #expect(model.isAnswerRevealed == false)
}

@Test @MainActor func studyModelReloadKeepsRevealedAnswerAndItsFeedback() async throws {
    let model = try await makeInteractionModel(.type, answer: .text("Paris"))
    model.updateTypedAnswer("London")
    model.submitTypedAnswer()
    #expect(model.isAnswerRevealed)
    #expect(model.answerEvaluation == .incorrect)

    var edited = try #require(model.currentCard?.item)
    let frontIndex = try #require(
        edited.fields.firstIndex(where: { $0.fieldID == BuiltInItemTypes.frontFieldID })
    )
    edited.fields[frontIndex].value = .text("Capital of France")
    _ = try await model.store.updateItem(edited)

    await model.reloadCurrentItem()

    #expect(model.isAnswerRevealed)
    #expect(model.answerEvaluation == .incorrect)
    #expect(model.typedAnswer == "London")
    #expect(
        model.currentCard?.item.value(for: BuiltInItemTypes.frontFieldID)
            == .text("Capital of France")
    )
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

/// A queue that cannot be read is not a finished session. Reporting completion
/// here sent learners back to a scope home that still said cards were due.
@Test @MainActor func studyModelReportsAQueueThatCannotBeReadAsAFailure() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
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

    var handle: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path(percentEncoded: false), &handle) == SQLITE_OK)
    #expect(
        sqlite3_exec(handle, "UPDATE cards SET memory = X'6e6f74206a736f6e';", nil, nil, nil)
            == SQLITE_OK
    )
    sqlite3_close(handle)

    let model = StudyModel(store: store)
    await model.startSession()

    #expect(model.didFailToLoad)
    #expect(model.errorMessage != nil)
    #expect(model.currentCard == nil)
}

@Test @MainActor func progressiveRemainderFailureRestoresAtomicFailureScreen() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-remainder-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
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
                    FieldValue(
                        fieldID: BuiltInItemTypes.backFieldID,
                        value: .text("A\(index)")
                    ),
                ]
            )
        )
    }
    let ordered = try await store.fetchDueCards()
    let corruptCardID = try #require(ordered.last?.id)
    var handle: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path(percentEncoded: false), &handle) == SQLITE_OK)
    let corruptCardSQL = """
        UPDATE cards
        SET memory = X'6e6f74206a736f6e'
        WHERE id = '\(corruptCardID.uuidString)';
        """
    #expect(sqlite3_exec(handle, corruptCardSQL, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let gate = StudyQueueLoadGate()
    let model = StudyModel(
        store: store,
        remainingQueueLoadGate: { await gate.wait() }
    )

    let startTask = Task { await model.startSession() }
    try await waitForProgressiveStudyHead(model)
    #expect(model.currentCard?.id == ordered[0].id)
    #expect(model.progressLabel == "Card 1 of 2")

    await gate.open()
    await startTask.value

    #expect(model.didFailToLoad)
    #expect(model.errorMessage != nil)
    #expect(model.queue.isEmpty)
    #expect(model.currentCard == nil)
    #expect(model.isPreparingQueue == false)
    #expect(model.isLoading == false)
}
