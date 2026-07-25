import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeStudyModel() async throws -> (StudyModel, ItemStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-study-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let databaseURL = url.appendingPathComponent("test.sqlite")
    let store = try ItemStore(databaseURL: databaseURL)
    try await store.bootstrap()
    return (StudyModel(store: store), store)
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

    #expect(model.isFinished == true)
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

    #expect(model.isFinished == true)
    #expect(try await store.dueCount() == 0)
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
    #expect(try await store.reviewLogCount(for: model.queue[0].id) == 0)
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
