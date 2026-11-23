import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import SQLite3
import Testing

import NeoAnkiApplication
@testable import NeoAnkiFeatures

@MainActor
private func sessionModel(
    store: ItemStore, remainingQueueLoadGate: (@Sendable () async -> Void)? = nil
) -> StudyFeatureModel {
    let model = StudyFeatureModel(library: SQLiteLibraryRepository(store: store), scope: .allDecks, title: "All Decks")
    model.remainingQueueLoadGate = remainingQueueLoadGate
    return model
}

@Test @MainActor func studyRestartClearsUndoCountersAndInteractionState() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    for index in 0..<3 {
        _ = try await store.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question \(index)")),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer \(index)")),
        ]))
    }
    await model.start()
    await model.grade(.easy)
    #expect(model.completion.uniqueCards == 1)
    await model.undoLastGrade()
    #expect(model.completion == .init(reviews: 0, uniqueCards: 0, uniqueItems: 0))
    await model.grade(.easy)
    #expect(model.canUndo)
    model.updateTypedAnswer("Unsubmitted draft")
    model.revealAnswer()

    await model.start()

    #expect(!model.canUndo)
    #expect(model.completion == .init(reviews: 0, uniqueCards: 0, uniqueItems: 0))
    #expect(model.typedAnswer.isEmpty)
    #expect(!model.isAnswerRevealed)
    #expect(model.answerEvaluation == nil)
    await model.grade(.easy)
    #expect(model.completion == .init(reviews: 1, uniqueCards: 1, uniqueItems: 1))
}

private final class StudyStartClock: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var instant: Date

    init(_ instant: Date = .now.addingTimeInterval(60)) {
        self.instant = instant
    }

    func set(_ instant: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.instant = instant
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return instant
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

@Test @MainActor func studyStartupCapturesOneClockInstantForAllReads() async throws {
    let (_, store) = try await makeStudyFeatureModel()
    _ = try await PerformanceFixtures.seedBasicItems(count: 2, in: store)
    let clock = StudyStartClock()
    let model = StudyFeatureModel(library: SQLiteLibraryRepository(store: store), scope: .allDecks,
                                 title: "Clock", clock: { clock.now() })
    await model.start()
    #expect(model.queue.count == 2)
    #expect(clock.count == 1)
}

@MainActor
private func makeStudyFeatureModel(
    scheduler: (any Scheduler)? = nil
) async throws -> (StudyFeatureModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL, scheduler: scheduler)
    try await store.bootstrap()
    return (sessionModel(store: store), store)
}

@MainActor
private func makeInteractionModel(
    _ interaction: Interaction,
    answer: ContentValue = .text("one two"),
    missingCheckableAnswer: Bool = false
) async throws -> (StudyFeatureModel, ItemStore) {
    let (model, store) = try await makeStudyFeatureModel()
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
    await model.start()
    return (model, store)
}

private actor StudyQueueLoadGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            hasEntered = true
            let entered = entryWaiters
            entryWaiters.removeAll()
            entered.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
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
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        invocationCount += 1
        guard invocationCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstWaiter = continuation
            hasEntered = true
            let entered = entryWaiters
            entryWaiters.removeAll()
            entered.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseFirst() {
        firstWaiter?.resume()
        firstWaiter = nil
    }
}

@Test @MainActor func studyModelStartsScopedSession() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start(scope: .deck(deck.id), title: "Geography")

    #expect(model.queue.count == 1)
    #expect(model.title == "Geography")
}

@Test @MainActor func studyModelPublishesExactHeadBeforeCompletingQueue() async throws {
    let (_, store) = try await makeStudyFeatureModel()
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
    let model = sessionModel(
        store: store,
        remainingQueueLoadGate: { await gate.wait() }
    )

    let startTask = Task { await model.start() }
    await gate.waitUntilEntered()
    #expect(model.isPreparingQueue)
    #expect(model.currentCard != nil)
    #expect(!model.isLoading)

    #expect(model.queue.map(\.id) == [expected[0].id])
    #expect(model.remainingCount == 2)
    #expect(model.isFinished == false)
    model.revealAnswer()
    #expect(model.isAnswerRevealed)

    await model.grade(.good)
    await model.skip()
    #expect(model.index == 0)
    #expect(model.completion.reviews == 0)
    #expect(try await store.reviewLogCount(for: expected[0].id) == 0)

    await gate.open()
    await startTask.value

    #expect(model.isPreparingQueue == false)
    #expect(model.queue.map(\.id) == expected.map(\.id))
    #expect(model.remainingCount == 2)
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
    let model = sessionModel(
        store: store,
        remainingQueueLoadGate: { await probe.record() }
    )

    await model.start()

    #expect(await probe.invocationCount == 0)
    #expect(model.isPreparingQueue == false)
    #expect(model.queue.isEmpty)
    #expect(model.isFinished)
    #expect(model.didFailToLoad == false)
}

@Test @MainActor func newerStudyStartSupersedesPendingProgressiveLoad() async throws {
    let (_, store) = try await makeStudyFeatureModel()
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
    let model = sessionModel(
        store: store,
        remainingQueueLoadGate: { await gate.wait() }
    )
    let firstStart = Task { await model.start() }
    await gate.waitUntilEntered()
    #expect(model.isPreparingQueue)
    #expect(model.currentCard != nil)
    #expect(!model.isLoading)

    let secondScope = DeckScope.deck(secondDeck.id)
    await model.start(scope: secondScope, title: secondDeck.name)
    let secondQueue = model.queue
    await gate.releaseFirst()
    await firstStart.value

    #expect(model.title == secondDeck.name)
    #expect(model.queue == secondQueue)
    #expect(model.queue.count == 1)
    #expect(model.queue.first?.item.deckID == secondDeck.id)
    #expect(model.isPreparingQueue == false)
}

@Test @MainActor func studyModelRespectsDeckDailyNewLimit() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start(scope: .deck(deck.id), title: deck.name)

    #expect(model.queue.count == 1)
}

@Test @MainActor func studyModelStartsSessionWithDueCards() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.start()

    #expect(model.isLoading == false)
    #expect(model.queue.count == 1)
    #expect(model.currentCard != nil)
    #expect(model.isFinished == false)
}

@Test @MainActor func studyModelGradesCardAndFinishesSession() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.start()
    model.revealAnswer()
    await model.grade(.good)

    #expect(model.isFinished == true)
    #expect(model.currentCard == nil)

    let dueCount = try await store.dueCount()
    #expect(dueCount == 0)
}

@Test @MainActor func studySessionContinuesWithCardsThatBecomeDueInItsScope() async throws {
    let (_, store) = try await makeStudyFeatureModel()
    let parent = try await store.createDeck(Deck(name: "Study"))
    let child = try await store.createDeck(Deck(name: "Nested", parentID: parent.id))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let newDue = start.addingTimeInterval(60)
    let clock = StudyStartClock(start)
    let scope = DeckScope.deck(parent.id)
    let model = StudyFeatureModel(library: SQLiteLibraryRepository(store: store), scope: scope,
                                  title: parent.name, clock: { clock.now() })

    func addItem(_ question: String, deckID: UUID?, due: Date) async throws -> SavedItemSummary {
        try await store.createItem(Item(itemTypeID: BuiltInItemTypes.basicID, fields: [
            .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text(question)),
            .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ], deckID: deckID), now: due)
    }

    let first = try await addItem("Due at startup", deckID: parent.id, due: start)
    let nested = try await addItem("Due during study", deckID: child.id, due: newDue)
    _ = try await addItem("Outside the session", deckID: nil, due: newDue)
    _ = try await addItem("Due later", deckID: child.id, due: newDue.addingTimeInterval(60))
    await model.start()
    #expect(model.queue.map(\.item.id) == [first.id])

    clock.set(newDue)
    model.revealAnswer()
    await model.grade(.good)

    #expect(!model.isComplete)
    #expect(model.currentCard?.item.id == nested.id)
    #expect(model.remainingCount == 1)
    #expect(!model.isAnswerRevealed)
    #expect(model.completion.reviews == 1)
    #expect(model.canUndo)

    model.revealAnswer()
    await model.grade(.good)
    #expect(model.isComplete)
    #expect(model.completion.reviews == 2)
    #expect(try await store.dueCount(scope: scope, asOf: newDue) == 0)
    #expect(try await store.dueCount(asOf: newDue) == 1)
}

@Test @MainActor func studySessionCanReviewAScheduledCardAgainWhenItsIntervalElapses() async throws {
    let (_, store) = try await makeStudyFeatureModel()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await PerformanceFixtures.seedBasicItems(count: 2, in: store, now: start)
    let clock = StudyStartClock(start)
    let model = StudyFeatureModel(library: SQLiteLibraryRepository(store: store), scope: .allDecks,
                                  title: "All Decks", clock: { clock.now() })
    await model.start()
    let first = try #require(model.currentCard)
    await model.grade(.good)
    let scheduled = try await store.card(id: first.id)
    #expect(scheduled.memory.due > start)

    clock.set(scheduled.memory.due)
    await model.grade(.good)

    #expect(model.currentCard?.id == first.id)
    #expect(model.currentCard?.card.memory == scheduled.memory)
    await model.grade(.good)
    #expect(model.isComplete)
    #expect(model.completion == .init(reviews: 3, uniqueCards: 2, uniqueItems: 2))
}

@Test @MainActor func everyInteractionKeyboardPrimaryPathReachesGradingAndCompletion() async throws {
    for interaction in [Interaction.reveal, .type, .choose, .record, .cloze, .arrange] {
        let (model, _) = try await makeInteractionModel(interaction)

        switch interaction {
        case .type:
            model.updateTypedAnswer("one two")
        case .choose:
            model.selectChoice(try #require(model.choiceOptions.first))
        case .arrange:
            model.selectArrangementItem(at: 0)
            model.moveSelectedArrangementItem(by: 1)
        case .reveal, .record, .cloze, .imageOcclusion:
            break
        case .audioSubmission:
            break
        }

        model.performPrimaryAction()
        #expect(model.isAnswerRevealed, "Primary keyboard action should reveal \(interaction)")

        await model.grade(.good)
        #expect(model.isFinished, "\(interaction) should be completable")
    }
}

@Test @MainActor func textOnlyRecordingCardStatesThatReferenceAudioIsUnavailable() async throws {
    let (model, _) = try await makeInteractionModel(.record)

    model.performPrimaryAction()

    #expect(model.isAnswerRevealed)
    #expect(
        model.interactionMessage
            == "No reference audio is available for this card. Replay your recording and compare it with the written answer."
    )
}

@Test @MainActor func interactionInputValidationDoesNotSoftLock() async throws {
    let (typeModel, _) = try await makeInteractionModel(.type)
    typeModel.performPrimaryAction()

    #expect(typeModel.isAnswerRevealed == false)
    #expect(typeModel.interactionMessage != nil)

    typeModel.revealAnswer()
    #expect(typeModel.isAnswerRevealed)

    let (choiceModel, _) = try await makeInteractionModel(.choose)
    choiceModel.performPrimaryAction()
    #expect(choiceModel.isAnswerRevealed == false)
    #expect(choiceModel.interactionMessage != nil)
    choiceModel.revealAnswer()
    #expect(choiceModel.isAnswerRevealed)
}

@Test @MainActor func typedAnswersAreEvaluatedAgainstRenderedAnswer() async throws {
    let (correct, _) = try await makeInteractionModel(.type, answer: .text("Paris"))
    correct.updateTypedAnswer("  PARIS! ")
    #expect(correct.reviewResponse == nil)
    correct.submitTypedAnswer()
    #expect(correct.isAnswerRevealed)
    #expect(correct.answerEvaluation == .correct)
    #expect(correct.reviewResponse == "  PARIS! ")

    let (incorrect, _) = try await makeInteractionModel(.type, answer: .text("Paris"))
    incorrect.updateTypedAnswer("London")
    incorrect.submitTypedAnswer()
    #expect(incorrect.isAnswerRevealed)
    #expect(incorrect.answerEvaluation == .incorrect)
    #expect(incorrect.reviewResponse == "London")
    incorrect.updateTypedAnswer("")
    #expect(incorrect.typedAnswer == "London")
    #expect(incorrect.answerEvaluation == .incorrect)
    await incorrect.grade(.good)
    #expect(incorrect.reviewResponse == nil)
}

@Test @MainActor func answerReviewDoesNotInventAnUnsubmittedResponse() async throws {
    let (model, _) = try await makeInteractionModel(.type)
    model.revealAnswer()
    #expect(model.reviewResponse == nil)
}

@Test @MainActor func answerReviewKeepsChoiceAndCharacterArrangement() async throws {
    let (choice, _) = try await makeInteractionModel(.choose, answer: .text("Paris"))
    choice.selectChoice("Paris")
    choice.submitChoice()
    #expect(choice.reviewResponse == "Paris")

    let (characters, _) = try await makeInteractionModel(.arrange, answer: .text("word"))
    let submitted = characters.arrangedItems.joined()
    characters.submitArrangement()
    #expect(characters.reviewResponse == submitted)
}

@Test @MainActor func missingAnswerRecoversToSelfGradeAndCompletion() async throws {
    let (model, _) = try await makeInteractionModel(.type, missingCheckableAnswer: true)

    model.performPrimaryAction()

    #expect(model.isAnswerRevealed)
    #expect(model.answerEvaluation == .unavailable)
    await model.grade(.good)
    #expect(model.isFinished)
}

@Test @MainActor func arrangementKeyboardMovesSelectedItem() async throws {
    let (model, _) = try await makeInteractionModel(.arrange, answer: .text("first second third"))
    let initial = model.arrangedItems

    model.selectArrangementItem(at: 0)
    model.moveSelectedArrangementItem(by: 1)

    #expect(model.selectedArrangementIndex == 1)
    #expect(model.arrangedItems != initial)
}

@Test @MainActor func arrangementMoveWithoutSelectionGuidesUserAndIgnoresBadIndices() async throws {
    let (model, _) = try await makeInteractionModel(.arrange, answer: .text("first second third"))
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

@Test @MainActor func studyModelMovesSkippedCardToEndWithoutReviewingIt() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    let itemType = try await store.defaultItemType()
    for index in 1...3 {
        _ = try await store.createItem(Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q\(index)")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A\(index)")),
            ]
        ))
    }

    await model.start()
    let originalOrder = model.queue.map(\.id)
    await model.skip()

    #expect(model.queue.map(\.id) == [originalOrder[1], originalOrder[2], originalOrder[0]])
    #expect(model.currentCard?.id == originalOrder[1])
    #expect(model.remainingCardCount == 3)
    #expect(model.completion.reviews == 0)
    #expect(model.isFinished == false)
    #expect(try await store.reviewLogCount(for: originalOrder[0]) == 0)
}

@Test @MainActor func studyModelKeepsOnlySkippedCardInSession() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    let itemType = try await store.defaultItemType()
    _ = try await store.createItem(Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    ))

    await model.start()
    let cardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.skip()

    #expect(model.currentCard?.id == cardID)
    #expect(model.remainingCardCount == 1)
    #expect(model.isAnswerRevealed == false)
    #expect(model.isFinished == false)
    #expect(try await store.reviewLogCount(for: cardID) == 0)
}

@Test @MainActor func studyModelMovesSkipBehindPendingRepairCards() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    let itemType = try await store.defaultItemType()
    for index in 1...2 {
        _ = try await store.createItem(Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q\(index)")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A\(index)")),
            ]
        ))
    }

    await model.start()
    let firstCardID = try #require(model.currentCard?.id)
    let skippedCardID = model.queue[1].id
    model.revealAnswer()
    await model.grade(.again)
    #expect(model.currentCard?.id == skippedCardID)

    await model.skip()

    #expect(model.currentCard?.id == firstCardID)
    #expect(model.queue.last?.id == skippedCardID)
    #expect(model.remainingCardCount == 2)
    #expect(try await store.reviewLogCount(for: skippedCardID) == 0)
}

@Test @MainActor func studyModelGradesAllRatings() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    #expect(model.queue.count == ReviewRating.allCases.count)

    for rating in ReviewRating.allCases {
        model.revealAnswer()
        await model.grade(rating)
    }

    #expect(model.isFinished == false)
    #expect(model.currentCard != nil)
    #expect(model.queue.count == ReviewRating.allCases.count + 1)
    #expect(model.completion.reviews == ReviewRating.allCases.count)
}

@Test @MainActor func studyModelEmptyQueueFinishesImmediately() async throws {
    let (model, _) = try await makeStudyFeatureModel()

    await model.start()

    #expect(model.isFinished == true)
    #expect(model.queue.isEmpty)
    #expect(model.currentCard == nil)
}

@Test @MainActor func studyModelAgainRatingSchedulesRelearning() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    model.revealAnswer()
    await model.grade(.again)

    #expect(model.isFinished == false)
    #expect(model.currentCard?.id == model.queue[0].id)
    #expect(model.queue.count == 2)
    #expect(model.remainingCount == 1)
    #expect(try await store.dueCount() == 1)
}

@Test @MainActor func studyModelFinishesInitialQueueBeforeRepairRound() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    let failedCardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.again)

    #expect(model.currentCard?.id != failedCardID)
    #expect(model.remainingCount == 2)

    model.revealAnswer()
    await model.grade(.good)

    #expect(model.currentCard?.id == failedCardID)
    #expect(model.queue.count == 3)
    #expect(model.remainingCount == 1)
}

@Test @MainActor func undoAgainRemovesPendingLearningRepeat() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    model.revealAnswer()
    await model.grade(.again)
    #expect(model.queue.count == 2)
    #expect(model.currentCard != nil)
    #expect(model.remainingCount == 1)

    await model.undoLastGrade()

    #expect(model.queue.count == 1)
    #expect(model.currentCard != nil)
    #expect(model.remainingCount == 1)
    #expect(model.completion.reviews == 0)
    #expect(try await store.dueCount() == 1)
}

@Test @MainActor func undoRepeatedGradeKeepsEarlierReviewedMembership() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Q")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("A")),
        ]
    )
    _ = try await store.createItem(item)

    await model.start()
    let cardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.again)
    model.revealAnswer()
    await model.grade(.again)

    #expect(model.completion.reviews == 2)
    #expect(model.reviewedCardIDs == [cardID])
    #expect(model.reviewedItemIDs == [item.id])

    await model.undoLastGrade()

    #expect(model.completion.reviews == 1)
    #expect(model.reviewedCardIDs == [cardID])
    #expect(model.reviewedItemIDs == [item.id])
    #expect(model.currentCard?.id == cardID)
    #expect(model.isAnswerRevealed)
}

@Test @MainActor func repeatedFailureStaysInCurrentSessionUntilRecall() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    let cardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.again)
    #expect(model.currentCard?.id == cardID)
    #expect(model.currentCard?.card.memory.stepIndex == 0)
    #expect(model.remainingCount == 1)

    model.revealAnswer()
    await model.grade(.again)
    #expect(!model.isFinished)
    #expect(model.currentCard?.id == cardID)
    #expect(model.remainingCount == 1)
    #expect(model.completion.reviews == 2)
    #expect(model.reviewedCardIDs == [cardID])
    #expect(try await store.reviewLogCount(for: cardID) == 2)
    let repairing = try await store.card(id: cardID)
    #expect(repairing.memory.phase == .learning)
    #expect(repairing.memory.stepIndex == 1)
    #expect(repairing.memory.due <= Date.now)

    model.revealAnswer()
    await model.grade(.good)
    #expect(model.isFinished)
    #expect(model.currentCard == nil)
    #expect(model.remainingCount == 0)
    #expect(model.completion.reviews == 3)
    #expect(try await store.reviewLogCount(for: cardID) == 3)
}

@Test @MainActor func studyModelUndoLastGradeRestoresCard() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    model.revealAnswer()
    await model.grade(.good)

    #expect(model.canUndo)
    #expect(model.remainingCount == 1)

    await model.undoLastGrade()

    #expect(model.canUndo == false)
    #expect(model.isAnswerRevealed)
    #expect(model.remainingCount == 2)
    #expect(try await store.rawReviewLogCount(for: model.queue[0].id) == 1)
    #expect(try await store.activeReviewLogCount(for: model.queue[0].id) == 0)
}

@Test @MainActor func studyModelRejectsConcurrentGrades() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
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
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    #expect(model.currentCard?.template.interaction == .cloze)

    model.revealAnswer()
    #expect(model.isAnswerRevealed)
    await model.grade(.good)

    #expect(model.isFinished)
    #expect(model.index == 1)
    #expect(try await store.reviewLogCount(for: model.queue[0].id) == 1)
}

@Test @MainActor func studyModelUndoAfterLastCardRestoresFinishedSession() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    let cardID = try #require(model.currentCard?.id)
    model.revealAnswer()
    await model.grade(.good)
    #expect(model.isFinished)
    #expect(model.canUndo)

    await model.undoLastGrade()

    #expect(model.isFinished == false)
    #expect(model.currentCard?.id == cardID)
    #expect(model.isAnswerRevealed)
    #expect(model.index == 0)
    #expect(try await store.reviewLogCount(for: cardID) == 0)
}

@Test @MainActor func studyModelDiscardsDeletedCardAndContinuesSession() async throws {
    let (model, store) = try await makeStudyFeatureModel()
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

    await model.start()
    let deletedCard = try #require(model.currentCard)
    #expect(try await store.deleteItem(id: deletedCard.item.id))

    model.revealAnswer()
    await model.grade(.good)

    #expect(model.error == nil)
    #expect(model.isFinished == false)
    #expect(model.queue.count == 1)
    #expect(model.currentCard?.id != deletedCard.id)
    #expect(model.isAnswerRevealed == false)
}

@Test @MainActor func studyModelReloadShowsEditedContentOnEveryQueuedCardOfThatItem() async throws {
    let (model, store) = try await makeStudyFeatureModel()
    var itemType = try await store.defaultItemType()
    itemType.templates[0].interaction = .cloze
    let frontIndex = try #require(
        itemType.fields.firstIndex(where: { $0.id == BuiltInItemTypes.frontFieldID })
    )
    itemType.fields[frontIndex].type = .cloze
    _ = try await store.updateItemType(itemType)
    let learnedAt = Date.now.addingTimeInterval(-100 * 86_400)
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
        ),
        now: learnedAt
    )
    for card in try await store.cards() {
        _ = try await store.submitReview(cardID: card.id, rating: .good, now: learnedAt)
    }

    await model.start()
    #expect(model.queue.count == 2)

    var edited = try #require(model.currentCard?.item)
    let backIndex = try #require(
        edited.fields.firstIndex(where: { $0.fieldID == BuiltInItemTypes.backFieldID })
    )
    edited.fields[backIndex].value = .text("Context, with the typo fixed")
    _ = try await store.updateItem(edited)

    await model.reloadCurrentItem()

    #expect(model.error == nil)
    #expect(model.queue.count == 2)
    for card in model.queue {
        #expect(card.item.value(for: BuiltInItemTypes.backFieldID) == .text("Context, with the typo fixed"))
    }
}

@Test @MainActor func studyModelReloadRederivesInteractionBeforeReveal() async throws {
    let (model, store) = try await makeInteractionModel(.choose, answer: .text("Pariss"))
    #expect(model.choiceOptions.contains("Pariss"))

    var edited = try #require(model.currentCard?.item)
    let backIndex = try #require(
        edited.fields.firstIndex(where: { $0.fieldID == BuiltInItemTypes.backFieldID })
    )
    edited.fields[backIndex].value = .text("Paris")
    _ = try await store.updateItem(edited)

    await model.reloadCurrentItem()

    #expect(model.choiceOptions.contains("Paris"))
    #expect(model.choiceOptions.contains("Pariss") == false)
    #expect(model.isAnswerRevealed == false)
}

@Test @MainActor func studyModelReloadKeepsRevealedAnswerAndItsFeedback() async throws {
    let (model, store) = try await makeInteractionModel(.type, answer: .text("Paris"))
    model.updateTypedAnswer("London")
    model.submitTypedAnswer()
    #expect(model.isAnswerRevealed)
    #expect(model.answerEvaluation == .incorrect)

    var edited = try #require(model.currentCard?.item)
    let frontIndex = try #require(
        edited.fields.firstIndex(where: { $0.fieldID == BuiltInItemTypes.frontFieldID })
    )
    edited.fields[frontIndex].value = .text("Capital of France")
    _ = try await store.updateItem(edited)

    await model.reloadCurrentItem()

    #expect(model.isAnswerRevealed)
    #expect(model.answerEvaluation == .incorrect)
    #expect(model.typedAnswer == "London")
    #expect(
        model.currentCard?.item.value(for: BuiltInItemTypes.frontFieldID)
            == .text("Capital of France")
    )
}

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

    let model = sessionModel(store: store)
    await model.start()

    #expect(model.didFailToLoad)
    #expect(!model.isComplete)
    #expect(model.error != nil)
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
    let model = sessionModel(
        store: store,
        remainingQueueLoadGate: { await gate.wait() }
    )

    let startTask = Task { await model.start() }
    await gate.waitUntilEntered()
    #expect(model.isPreparingQueue)
    #expect(model.currentCard != nil)
    #expect(!model.isLoading)
    #expect(model.currentCard?.id == ordered[0].id)
    #expect(model.remainingCount == 2)

    await gate.open()
    await startTask.value

    #expect(model.didFailToLoad)
    #expect(!model.isComplete)
    #expect(model.error != nil)
    #expect(model.queue.isEmpty)
    #expect(model.currentCard == nil)
    #expect(model.isPreparingQueue == false)
    #expect(model.isLoading == false)
}
