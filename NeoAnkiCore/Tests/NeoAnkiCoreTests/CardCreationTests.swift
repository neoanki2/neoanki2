import Foundation
import Testing
@testable import NeoAnkiCore

@Suite struct CardCreationTests {
    private func options(_ name: String, _ values: [ContentValue], type: FieldType = .text) -> ItemList {
        let column = FieldDef(name: name, type: type, isRequired: true)
        return ItemList(name: name, columns: [column], sharedRows: values.map {
            ItemListRow(values: [FieldValue(fieldID: column.id, value: $0)])
        })
    }

    @Test func scalesUseOrdinaryTemplatesAndScheduleEachCombination() throws {
        let tempos = options("Tempos", [60, 72, 84, 96, 108].map { .number($0) }, type: .number)
        let hands = options("Hands", ["Left", "Right", "Both"].map { .text($0) })
        let dynamics = options("Dynamics", ["Piano", "Mezzo forte", "Forte"].map { .text($0) })
        let rhythms = options("Rhythms", ["Even", "Long-short", "Short-long"].map { .text($0) })
        let lists = [tempos, hands, dynamics, rhythms]
        var type = BuiltInItemTypes.basic
        type.lists = lists
        type.templates[0].cardCreation = CardCreation(listIDs: lists.map(\.id), startSuspended: true)
        for list in lists {
            type.templates[0].components.append(TemplateComponent(
                region: .supporting, purpose: .supporting, source: .field(list.columns[0].id)
            ))
        }
        try ItemTypeValidation.validate(type)
        let keys = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let counts = try keys.map { key in
            let item = Item(itemTypeID: type.id, fields: [
                .init(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Play the \(key) major scale.")),
                .init(fieldID: BuiltInItemTypes.backFieldID, value: .text("Check rhythm and evenness."))
            ])
            let cards = CardGenerator.cards(for: item, type: type, deterministicIDs: true)
            let first = try #require(cards.first)
            let study = DueCard(card: first, item: item, itemType: type, template: type.templates[0])
            #expect(study.response == .onYourOwn)
            #expect(study.studyComponents.map(\.value).contains(.number(60)))
            #expect(cards.allSatisfy { $0.isSuspended && $0.memory.phase == .new })
            #expect(Set(cards.map(\.id)).count == 135)
            var reordered = type
            reordered.templates[0].cardCreation?.listIDs.reverse()
            #expect(Set(CardGenerator.cards(for: item, type: reordered, deterministicIDs: true).map(\.id)) == Set(cards.map(\.id)))
            return cards.count
        }
        #expect(counts == Array(repeating: 135, count: 12))
        #expect(counts.reduce(0, +) == 1620)
    }

    @Test func responseDoesNotChangeBasicClozeOrMaskPrompt() throws {
        let front = FieldDef(name: "Prompt", type: .text)
        let answer = FieldDef(name: "Answer", type: .text)
        let blank = FieldDef(name: "Blank", type: .cloze)
        let mask = FieldDef(name: "Mask", type: .imageOcclusion)
        let image = MediaRef(kind: .image, assetHash: String(repeating: "a", count: 64), fileExtension: "png")
        let occlusion = ImageOcclusionContent(image: image, masks: [
            ImageOcclusionMask(group: 1, rect: OcclusionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), answerText: "right atrium"),
            ImageOcclusionMask(group: 2, rect: OcclusionRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), answerText: "left atrium"),
        ], nextGroup: 3)
        let values: [FieldValue] = [
            .init(fieldID: front.id, value: .text("Capital of Spain?")),
            .init(fieldID: answer.id, value: .text("Madrid")),
            .init(fieldID: blank.id, value: .cloze("Madrid and Toledo", blanks: [
                ClozeSpan(group: 1, start: 0, length: 6), ClozeSpan(group: 2, start: 11, length: 6),
            ])),
            .init(fieldID: mask.id, value: .imageOcclusion(occlusion)),
        ]
        let cases: [(Interaction, UUID, UUID, [String])] = [
            (.reveal, front.id, answer.id, ["Madrid"]),
            (.cloze, blank.id, blank.id, ["Madrid", "Toledo"]),
            (.imageOcclusion, mask.id, answer.id, ["right atrium", "left atrium"]),
        ]
        for (interaction, source, expected, answers) in cases {
            var template = Template(name: "Test", layout: .focus, components: [
                .init(region: .primary, purpose: .question, source: .field(source)),
                .init(region: .secondary, purpose: .expectedAnswer, source: .field(expected), presentation: .init(reveal: .hiddenUntilAnswer)),
            ], interaction: interaction, skill: .init(input: .text, output: .freeResponse, operation: .recall))
            var type = ItemType(name: "Test", fields: [front, answer, blank, mask], templates: [template])
            let item = Item(itemTypeID: type.id, fields: values)
            let cards = CardGenerator.cards(for: item, type: type, deterministicIDs: true)
            let original = cards.map { DueCard(card: $0, item: item, itemType: type, template: template).studyComponents }
            template.responseOverride = .type
            type.templates = [template]
            let typed = CardGenerator.cards(for: item, type: type, deterministicIDs: true)
            #expect(typed.map(\.id) == cards.map(\.id))
            #expect(typed.count == answers.count)
            for (index, card) in typed.enumerated() {
                let due = DueCard(card: card, item: item, itemType: type, template: template)
                #expect(due.response == .type)
                #expect(due.studyComponents == original[index])
                #expect(StudyResponseEvaluator.acceptedAnswers(for: due) == [answers[index]])
                #expect(StudyResponseEvaluator.evaluate(answers[index], for: due) == .correct)
                #expect(StudyResponseEvaluator.evaluate("No match", for: due) == .incorrect)
            }
        }
    }

    @Test func appendingAFilteredVocabularyExampleKeepsCardIDsAndReviewHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ItemStore(databaseURL: root.appendingPathComponent("source.sqlite"), starterItemTypes: [])
        try await source.bootstrap()
        let deck = try await source.createDeck(Deck(name: "Spanish"))
        let now = Date(timeIntervalSince1970: 1_795_852_800)
        let term = VocabularyTerm(language: "es", expression: "laguna")
        let initial = VocabularySetDraft(term: term, meaning: "lagoon", meaningLanguage: "en",
                                         sentence: "La laguna está cerca de la casa.", deckID: deck.id)
        let id = try await source.createVocabularySet(initial, now: now)
        let original = try #require(try await source.fetchItem(id: id))
        let firstCards = CardGenerator.cards(for: original.item, type: original.itemType, deterministicIDs: true)
        let receipt = try await source.submitReviewWithReceipt(cardID: firstCards[0].id, rating: .good, now: now)
        let memory = try await source.card(id: firstCards[0].id)

        let extra = VocabularySetDraft(term: term, meaning: "lagoon", meaningLanguage: "en",
                                       sentence: "La laguna creció después de las lluvias.", deckID: deck.id)
        #expect(try await source.matchingVocabularySets(extra).map(\.id) == [id])
        let extraID = UUID()
        try await source.appendVocabularyExample(extra, to: id, exampleID: extraID, recognition: false, now: now)
        try await source.appendVocabularyExample(extra, to: id, exampleID: extraID, recognition: false, now: now)
        let duplicateID = UUID()
        try await source.appendVocabularyExample(extra, to: id, exampleID: duplicateID, recognition: false, now: now)
        let latest = try #require(try await source.fetchItem(id: id))
        let latestCards = CardGenerator.cards(for: latest.item, type: latest.itemType, deterministicIDs: true)
        #expect(latestCards.count == 4)
        #expect(try await source.card(id: firstCards[0].id) == memory)
        #expect(try await source.reviewLog(id: receipt.reviewLogID).vocabularyPrompt != nil)
        let newCard = try #require(latestCards.first { $0.rowSelections.contains { $0.rowID == extraID } })
        #expect(newCard.templateID == VocabularySet.productionID)
        let duplicate = try #require(latestCards.first { $0.rowSelections.contains { $0.rowID == duplicateID } })
        #expect(duplicate.id != newCard.id)
        let template = try #require(latest.itemType.templates.first { $0.id == newCard.templateID })
        let study = DueCard(card: newCard, item: latest.item, itemType: latest.itemType, template: template)
        #expect(StudyResponseEvaluator.evaluate("laguna", for: study) == .correct)
        #expect(StudyResponseEvaluator.evaluate("La laguna", for: study) == .incorrect)

        let package = root.appendingPathComponent("vocabulary.neodeck")
        try await PortableDeck.export(deckID: deck.id, from: source, to: package)
        let target = try ItemStore(databaseURL: root.appendingPathComponent("target.sqlite"), starterItemTypes: [])
        try await target.bootstrap()
        let result = try await PortableDeck.importDeck(from: package, into: target)
        #expect(result.itemCount == 1)
        let copiedID = try #require(try await target.listItems().first?.id)
        let copied = try #require(try await target.fetchItem(id: copiedID))
        #expect(try copied.itemType.portableSchemaDigest() == latest.itemType.portableSchemaDigest())
        #expect(CardGenerator.cards(for: copied.item, type: copied.itemType).count == 4)
        #expect(VocabularySet.term(in: copied.item) == term)
        #expect(try await target.vocabularyStatuses(language: "es").first?.hasCards == true)
    }
}
