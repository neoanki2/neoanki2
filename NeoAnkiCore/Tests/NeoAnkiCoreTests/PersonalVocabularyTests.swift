import Foundation
import NeoAnkiCore
import Testing

@Suite struct PersonalVocabularyTests {
    private func store() throws -> ItemStore {
        try ItemStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("known-words-\(UUID().uuidString).sqlite"), starterItemTypes: [])
    }

    @Test func cardSetCreatesTwoNativeCardsAndChecksTheExactClozeSpan() async throws {
        let store = try store()
        try await store.bootstrap()
        let draft = VocabularySetDraft(term: .init(language: "es", expression: "aprovechó"),
            meaning: "made good use of", meaningLanguage: "en", sentence: "Ana aprovechó la pausa para llamar.",
            productionSentence: "Ayer, los viajeros aprovecharon la escala.", productionForm: "aprovecharon")
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let id = UUID()
        #expect(try await store.createVocabularySet(draft, id: id, now: now) == id)
        #expect(try await store.createVocabularySet(draft, id: id, now: now) == id)
        let saved = try #require(try await store.fetchItem(id: id))
        let generated = CardGenerator.cards(for: saved.item, type: saved.itemType, now: now)
        #expect(generated.count == 2)
        let reading = try #require(generated.first { $0.templateID == VocabularySet.readingID })
        let production = try #require(generated.first { $0.templateID == VocabularySet.productionID })
        #expect(production.clozeGroup == 1)
        let template = try #require(saved.itemType.templates.first { $0.id == production.templateID })
        let card = DueCard(card: production, item: saved.item, itemType: saved.itemType, template: template)
        #expect(template.interaction == .cloze)
        #expect(VocabularySet.productionAnswer(for: card) == "aprovecharon")
        #expect(VocabularySet.check("aprovecharon", for: card) == .correct)
        #expect(VocabularySet.check("aprovechó", for: card) == .incorrect)
        #expect(try await store.fetchDueCards(asOf: now).map(\.template.id) == [reading.templateID])
        let status = try #require(try await store.vocabularyStatuses(language: "es").first)
        #expect(status.hasCards && !status.isKnown && !status.clozeMature)

        let firstDue = try #require(try await store.fetchDueCards(asOf: now).first)
        _ = try await store.submitReview(cardID: firstDue.id, rating: .easy, now: now)
        #expect(try await store.fetchDueCards(asOf: now).isEmpty)
        let next = try #require(try await store.fetchDueCards(asOf: now.addingTimeInterval(86_400)).first)
        #expect(next.template.id == VocabularySet.productionID)
        #expect(VocabularySet.productionAnswer(for: next) == "aprovecharon")
    }

    @Test func judgmentsAreIndependentByLanguageAndClearEventsConverge() async throws {
        let first = try store()
        let second = try store()
        try await first.bootstrap()
        try await second.bootstrap()
        let known = VocabularyTerm(language: "en", expression: "Gift")
        let german = VocabularyTerm(language: "de", expression: "Gift")
        let later = Date(timeIntervalSince1970: 1_767_225_601)
        let mark = try await first.setVocabularyJudgment(.known, for: known, now: later)
        let clear = try await first.setVocabularyJudgment(.reviewHistory, for: known, now: later)
        let unrelated = try await second.setVocabularyJudgment(.known, for: german, now: later)
        try await second.mergeVocabularyJudgments([clear, mark, clear])
        try await first.mergeVocabularyJudgments([unrelated])
        #expect(try await first.vocabularyStatuses() == second.vocabularyStatuses())
        #expect(try await first.vocabularyStatuses(language: "en").isEmpty)
        #expect(try await first.vocabularyStatuses(language: "de").first?.isKnown == true)
        #expect(try await first.fetchDueCards().isEmpty)
    }

    @Test func spacedReadingAndProductionEvidenceLapseIndependently() async throws {
        let store = try store()
        try await store.bootstrap()
        let term = VocabularyTerm(language: "es", expression: "laguna")
        let draft = VocabularySetDraft(term: term, meaning: "lagoon", meaningLanguage: "en",
                                       sentence: "La laguna está cerca de la casa.")
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let id = try await store.createVocabularySet(draft, now: start)
        let saved = try #require(try await store.fetchItem(id: id))
        let cards = CardGenerator.cards(for: saved.item, type: saved.itemType, now: start, deterministicIDs: true)
        let reading = try #require(cards.first { $0.templateID == VocabularySet.readingID })
        let production = try #require(cards.first { $0.templateID == VocabularySet.productionID })
        for day in [0.0, 10, 25, 50] {
            let review = try await store.submitReviewWithReceipt(cardID: reading.id, rating: .easy,
                                                                 now: start.addingTimeInterval(day * 86_400))
            let log = try await store.reviewLog(id: review.reviewLogID)
            #expect(log.vocabularyPrompt != nil)
        }
        #expect(try await store.vocabularyStatuses().first?.isKnown == true)
        #expect(try await store.vocabularyStatuses().first?.clozeMature == false)
        for day in [1.0, 11, 26, 51] {
            _ = try await store.submitReview(cardID: production.id, rating: .easy, now: start.addingTimeInterval(day * 86_400))
        }
        #expect(try await store.vocabularyStatuses().first?.clozeMature == true)
        let lapseAt = start.addingTimeInterval(78 * 86_400)
        let lapse = try await store.submitReviewWithReceipt(cardID: production.id, rating: .again, now: lapseAt)
        #expect(try await store.vocabularyStatuses().first?.isKnown == true)
        #expect(try await store.vocabularyStatuses().first?.clozeMature == false)
        try await store.revertReview(reviewLogID: lapse.reviewLogID, now: lapseAt)
        #expect(try await store.vocabularyStatuses().first?.clozeMature == true)
        _ = try await store.setVocabularyJudgment(.unfamiliar, for: term)
        #expect(try await store.vocabularyStatuses().first?.isKnown == false)
        _ = try await store.setVocabularyJudgment(.reviewHistory, for: term)
        #expect(try await store.vocabularyStatuses().first?.isKnown == true)

        var edited = draft
        edited.sentence = "Visitamos la laguna después de comer."
        edited.productionSentence = draft.sentence
        edited.productionForm = "laguna"
        let item = try VocabularySet.makeItem(edited, id: id)
        _ = try await store.updateItem(item, now: lapseAt)
        let result = try #require(try await store.vocabularyStatuses().first)
        #expect(!result.isKnown)
        #expect(result.clozeMature)
    }

    @Test func termScopeAndClozeValidationPreserveMeaningfulDifferences() throws {
        let word = VocabularyTerm(language: "es", expression: "sí")
        let item = try VocabularySet.makeItem(.init(term: word, meaning: "yes", meaningLanguage: "en",
                                                   sentence: "Respondió que sí."), id: UUID())
        let type = VocabularySet.itemType
        let production = try #require(CardGenerator.cards(for: item, type: type).first { $0.clozeGroup != nil })
        let template = try #require(type.templates.first { $0.id == production.templateID })
        let card = DueCard(card: production, item: item, itemType: type, template: template)
        #expect(VocabularySet.check("si", for: card) == .incorrect)
        #expect(VocabularySet.check("si\u{301}", for: card) == .correct)
        #expect(throws: VocabularySetError.self) {
            try VocabularySet.makeItem(.init(term: word, meaning: "yes", meaningLanguage: "en",
                                             sentence: "Sí, me dijo que sí."), id: UUID())
        }
    }
}
