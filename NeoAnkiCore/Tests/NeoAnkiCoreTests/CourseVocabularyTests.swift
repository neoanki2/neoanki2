import Foundation
import Testing
@testable import NeoAnkiCore

@Test func courseRecognitionCountsInJapaneseAndRetainsOriginalReviewEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("course-vocabulary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"), starterItemTypes: [])
    try await store.bootstrap()
    let database = await store.database
    let start = Date(timeIntervalSince1970: 1_767_225_600)

    let legacy = BuiltInItemTypes.basic
    let term = VocabularyTerm(language: "ja", expression: "ねこ")
    let source = Item(itemTypeID: legacy.id, fields: [
        .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("ねこが昼寝する。")),
        .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("A cat takes a nap."))
    ], tags: ["migaku:vocabulary-fixture"])
    try await database.createScopedType(legacy, deckID: nil, shared: false)
    let previous = try #require(CardGenerator.cards(for: source, type: legacy, now: start).first)
    try await database.insertItemWithCards(source, cards: [previous], createdAt: start, updatedAt: start)
    for day in [0.0, 10, 25, 50] {
        _ = try await store.submitReview(cardID: previous.id, rating: .easy, now: start.addingTimeInterval(day * 86_400))
    }
    let original = try #require(try await database.fetchCard(id: previous.id))
    let reviews = try await database.fetchActiveReviewLogs(cardID: previous.id)
    #expect(reviews.count == 4)
    #expect(reviews.allSatisfy { $0.vocabularyPrompt == nil })
    #expect(try await store.vocabularyStatuses(language: "ja").isEmpty)

    let draft = VocabularySetDraft(term: term, meaning: "A cat takes a nap.", meaningLanguage: "en",
                                   sentence: "ねこが昼寝する。")
    var type = VocabularySet.itemType
    let setup = try #require(type.templates.first?.cardCreation)
    let recognition = try #require(setup.checkedFieldIDs?.first)
    let answer = try #require(type.field(named: "Meaning"))
    let template = Template(id: previous.templateID, name: "Course recognition", layout: .focus, components: [
        .init(region: .primary, purpose: .question, source: .field(VocabularySet.courseSentence.id)),
        .init(region: .secondary, purpose: .expectedAnswer, source: .field(answer.id),
              presentation: .init(reveal: .hiddenUntilAnswer))
    ], interaction: .reveal, skill: previous.skill, generateWhen: .fieldNotEmpty(VocabularySet.courseSentence.id),
       cardCreation: setup)
    var list = VocabularySet.examples
    list.columns += [VocabularySet.courseSentence, VocabularySet.importedRecognitionPrompt]
    type.lists = [list]
    type.templates.append(template)
    #expect(VocabularySet.supportsDefinition(type))
    try ItemTypeValidation.validate(type)
    try await database.createScopedType(type, deckID: nil, shared: false)

    var item = try VocabularySet.makeItem(draft, id: source.id)
    item.fields.removeAll { $0.fieldID == list.id }
    var row = ItemListRow(id: source.id, values: [
        .init(fieldID: VocabularySet.courseSentence.id, value: .text("ねこが昼寝する。")),
        .init(fieldID: recognition, value: .checkbox(true))
    ])
    item.fields.append(.init(fieldID: list.id, value: .rows([row])))
    var migrated = original
    migrated.rowSelections = [.init(listID: list.id, rowID: row.id)]
    #expect(VocabularySet.isCourseRecognition(DueCard(card: migrated, item: item, itemType: type, template: template)))
    let initial = try #require(VocabularySet.prompt(for: migrated, item: item, type: type))
    row.values.append(.init(fieldID: VocabularySet.importedRecognitionPrompt.id, value: .text(initial)))
    let listIndex = try #require(item.fields.firstIndex { $0.fieldID == list.id })
    item.fields[listIndex].value = .rows([row])
    #expect(StudyCardRelation.family(for: source) == StudyCardRelation.family(for: item))
    try await database.execute("UPDATE cards SET row_selections = ? WHERE id = ?;", bindings: [
        .blob(try JSONEncoder().encode(migrated.rowSelections)), .text(migrated.id.uuidString)
    ])
    let now = start.addingTimeInterval(90 * 86_400)
    try await database.updateItemWithMedia(item, desiredCards: [migrated], updatedAt: now, mediaDescriptors: [:])
    #expect(try await database.fetchCard(id: original.id) == migrated)
    #expect(try await database.fetchActiveReviewLogs(cardID: original.id) == reviews)
    #expect(try await store.vocabularyStatuses(language: "ja").first?.isKnown == true)
    #expect(try await store.vocabularyStatuses(language: "ja").first?.clozeMature == false)
    #expect(try await store.vocabularyStatuses(language: "en").isEmpty)

    let receipt = try await store.submitReviewWithReceipt(cardID: original.id, rating: .easy, now: now)
    #expect(try await store.reviewLog(id: receipt.reviewLogID).vocabularyPrompt == initial)
    row.values[0].value = .text("白いねこが歩いている。")
    item.fields[listIndex].value = .rows([row])
    _ = try await store.updateItem(item, now: now)
    #expect(try await store.vocabularyStatuses(language: "ja").first?.state == .learning)

    let regularID = try await store.createVocabularySet(draft, now: now)
    #expect(try await database.fetchCards(for: regularID).map(\.templateID).sorted(by: { $0.uuidString < $1.uuidString })
            == [VocabularySet.readingID, VocabularySet.productionID])
}
