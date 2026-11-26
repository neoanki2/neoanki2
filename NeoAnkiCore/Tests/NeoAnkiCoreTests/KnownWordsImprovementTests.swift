import Foundation
import NeoAnkiCore
import Testing

@Suite struct KnownWordsImprovementTests {
    private func store() async throws -> ItemStore {
        let store = try ItemStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("known-words-\(UUID().uuidString).sqlite"), starterItemTypes: [])
        try await store.bootstrap()
        return store
    }

    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    /// Create a Vocabulary Set and make its reading card reading-mature.
    private func matureSet(_ store: ItemStore, term: VocabularyTerm, sentence: String) async throws -> (item: UUID, reading: UUID) {
        let draft = VocabularySetDraft(term: term, meaning: "meaning", meaningLanguage: "en", sentence: sentence)
        let id = try await store.createVocabularySet(draft, now: start)
        let saved = try #require(try await store.fetchItem(id: id))
        let cards = CardGenerator.cards(for: saved.item, type: saved.itemType, now: start, deterministicIDs: true)
        let reading = try #require(cards.first { $0.templateID == VocabularySet.readingID })
        for day in [0.0, 10, 25, 50] {
            _ = try await store.submitReview(cardID: reading.id, rating: .easy, now: start.addingTimeInterval(day * 86_400))
        }
        return (id, reading.id)
    }

    // MARK: 0.1 Forward-compatible judgments

    @Test func judgmentsFromNewerReleasesMergeWithoutStoppingSync() async throws {
        let store = try await store()
        let payload = Data("""
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","term":{"language":"en","expression":"Gift","future":1},
             "judgment":"partlyKnown","changedAt":800000000,"somethingNew":{"a":1}}
            """.utf8)
        try await store.mergeVocabularyJudgmentPayloads([payload])
        // Read as no judgment, so the term is not listed and nothing claims it is known.
        #expect(try await store.vocabularyStatuses(language: "en").isEmpty)
        let snapshot = try await store.vocabularySnapshot(language: "en")
        #expect(snapshot.state(of: "gift") == .unassessed)
    }

    @Test func ignoredIsWrittenSoEarlierReleasesReadItAsNotKnown() throws {
        let change = VocabularyJudgmentChange(id: UUID(), term: .init(language: "uk", expression: "Київ"),
                                              judgment: .ignored, changedAt: start)
        let data = try JSONEncoder().encode(change)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["judgment"] as? String == "unfamiliar")
        #expect(object["ignored"] as? Bool == true)
        #expect(try JSONDecoder().decode(VocabularyJudgmentChange.self, from: data).judgment == .ignored)

        // The shape a release without Ignored decodes: only three judgment values.
        struct EarlierChange: Decodable {
            enum Judgment: String, Decodable { case known, unfamiliar, reviewHistory }
            let id: UUID
            let judgment: Judgment
            let changedAt: Date
        }
        #expect(try JSONDecoder().decode(EarlierChange.self, from: data).judgment == .unfamiliar)
    }

    @Test func unrecognizedJudgmentsCannotBeRecorded() async throws {
        let store = try await store()
        await #expect(throws: VocabularySetError.self) {
            _ = try await store.setVocabularyJudgment(.unrecognized, for: .init(language: "en", expression: "x"))
        }
    }

    // MARK: 0.2 One rule for every surface

    @Test func combinedStateFollowsTheGeneralJudgmentThenAnyMeaning() {
        func row(_ sense: String?, _ judgment: VocabularyJudgment? = nil, mature: Bool = false, cards: Bool = false) -> VocabularyStatus {
            VocabularyStatus(term: .init(language: "en", expression: "bank", sense: sense), judgment: judgment,
                             readingMature: mature, hasCards: cards)
        }
        #expect(VocabularyStatus.combinedState(of: [row("river", .known)]) == .known)
        #expect(VocabularyStatus.combinedState(of: [row(nil, .known), row("money", cards: true)]) == .known)
        #expect(VocabularyStatus.combinedState(of: [row(nil, .unfamiliar), row("money", mature: true)]) == .unfamiliar)
        #expect(VocabularyStatus.combinedState(of: [row(nil, .unfamiliar), row("money", cards: true)]) == .learning)
        #expect(VocabularyStatus.combinedState(of: [row("river"), row("money", cards: true)]) == .learning)
        #expect(VocabularyStatus.combinedState(of: [row(nil, .ignored), row("money", .known)]) == .ignored)
        #expect(VocabularyStatus.combinedState(of: [row(nil, .reviewHistory, mature: true)]) == .known)
        #expect(VocabularyStatus.combinedState(of: [row(nil, .unrecognized)]) == .unassessed)
    }

    @Test func aMeaningJudgmentMarksTheSpellingKnownInStatusesAndSnapshots() async throws {
        let store = try await store()
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "en", expression: "Bank", sense: "river edge"))
        _ = try await store.createVocabularySet(.init(term: .init(language: "en", expression: "bank", sense: "money"),
                                                      meaning: "a financial institution", meaningLanguage: "en",
                                                      sentence: "She went to the bank."), now: start)
        let statuses = try await store.vocabularyStatuses(language: "en")
        #expect(statuses.count == 2)
        #expect(statuses.allSatisfy { $0.expressionState == .known })
        #expect(try await store.vocabularySnapshot(language: "en").state(of: "BANK") == .known)
        #expect(try await store.vocabularyStatuses(language: "en", expression: " bank ").count == 2)
    }

    @Test func statusesEncodeTheirStatesForClients() throws {
        let status = VocabularyStatus(term: .init(language: "en", expression: "x"), judgment: .unrecognized, hasCards: true)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(object["state"] as? String == "learning")
        #expect(object["expressionState"] as? String == "learning")
        #expect(object["judgment"] == nil)
    }

    // MARK: 1.2 Bulk judgments

    @Test func batchesSkipUnchangedTermsRetrySafelyAndUndoTogether() async throws {
        let store = try await store()
        let one = VocabularyTerm(language: "es", expression: "uno")
        let two = VocabularyTerm(language: "es", expression: "dos")
        let three = VocabularyTerm(language: "es", expression: "tres")
        _ = try await store.setVocabularyJudgment(.unfamiliar, for: one, now: start)
        _ = try await store.setVocabularyJudgment(.known, for: three, now: start)
        let batch = UUID()
        let entries = [one, two, two, three].map { VocabularyJudgmentEntry(term: $0, judgment: .known) }
        let receipt = try await store.setVocabularyJudgments(entries, batchID: batch, now: start)
        #expect(receipt.recorded == 2 && receipt.unchanged == 2)
        let retried = try await store.setVocabularyJudgments(entries, batchID: batch, now: start)
        #expect(retried.recorded == 2 && retried.changes.map(\.id) == receipt.changes.map(\.id))
        #expect(try await store.vocabularyStatuses(language: "es").filter(\.isKnown).count == 3)

        // A later change by the learner is kept when the bulk action is undone.
        _ = try await store.setVocabularyJudgment(.ignored, for: two, now: start.addingTimeInterval(5))
        let undo = try await store.undoVocabularyBatch(batch, now: start.addingTimeInterval(10))
        #expect(undo.recorded == 1 && undo.unchanged == 1)
        let byExpression = Dictionary(uniqueKeysWithValues: try await store.vocabularyStatuses(language: "es")
            .map { ($0.term.expression, $0) })
        #expect(byExpression["uno"]?.judgment == .unfamiliar)
        #expect(byExpression["dos"]?.judgment == .ignored)
        #expect(byExpression["tres"]?.judgment == .known)
        await #expect(throws: VocabularySetError.self) { _ = try await store.undoVocabularyBatch(UUID()) }
    }

    @Test func listImportAcceptsPlainListsAndCSVAndExportRoundTrips() throws {
        let text = """
            expression,judgment,sense
            hola,known,
            "adiós, amigo",ignored,
            banco,unfamiliar,money
            """
        let parsed = try VocabularyListFormat.parse(text, language: "es")
        #expect(parsed.entries.map(\.term.expression) == ["hola", "adiós, amigo", "banco"])
        #expect(parsed.entries.map(\.judgment) == [.known, .ignored, .unfamiliar])
        #expect(parsed.entries[2].term.sense == "money")

        let plain = try VocabularyListFormat.parse("uno\n\n  dos  \n# comment\nUno\n", language: "es")
        #expect(plain.entries.map(\.term.expression) == ["uno", "dos"])
        #expect(plain.duplicates == 1)
        #expect(plain.entries.allSatisfy { $0.judgment == .known })

        let statuses = parsed.entries.map { VocabularyStatus(term: $0.term, judgment: $0.judgment) }
        let csv = VocabularyListFormat.csv(statuses)
        let again = try VocabularyListFormat.parse(csv, language: "es")
        #expect(again.entries.map(\.term) == parsed.entries.map(\.term))
        #expect(again.entries.map(\.judgment) == parsed.entries.map(\.judgment))
    }

    // MARK: 2 Dictionary forms

    @Test func matchKeysAgreeWithTheSharedVectors() throws {
        struct Vectors: Decodable { struct Vector: Decodable { let language, input, key: String }; let vectors: [Vector] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/vocabulary-match-keys.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).vectors
        #expect(!vectors.isEmpty)
        for vector in vectors {
            #expect(VocabularyTerm.matchKey(vector.input, language: vector.language) == vector.key,
                    "\(vector.language) \(vector.input)")
        }
    }

    @Test func inflectedFormsResolveThroughTheirDictionaryForm() async throws {
        let store = try await store()
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "uk", expression: "книжки", lemma: "кни́жка"))
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "uk", expression: "Ки́їв"))
        let snapshot = try await store.vocabularySnapshot(language: "uk")
        #expect(snapshot.lemmas["книжка"] == .known)
        #expect(snapshot.state(of: "книжку", lemmas: ["книжка"]) == .known)
        #expect(snapshot.state(of: "Київ") == .known)
        #expect(snapshot.state(of: "книжкою") == .unassessed)
        #expect(snapshot.state(of: "мати", lemmas: ["мати", "мама"]) == .unassessed)
        // A term's identity ignores the dictionary form, so earlier judgments still apply.
        #expect(VocabularyTerm(language: "uk", expression: "книжки", lemma: "книжка").id
            == VocabularyTerm(language: "uk", expression: "книжки").id)
    }

    @Test func snapshotVersionChangesOnlyWhenVocabularyMayHaveChanged() async throws {
        let store = try await store()
        let first = try await store.vocabularySnapshot(language: "en").version
        #expect(try await store.vocabularySnapshot(language: "en").version == first)
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "en", expression: "gift"))
        #expect(try await store.vocabularySnapshot(language: "en").version != first)
    }

    @Test func spellingsThatMatchTheSameKeyFollowTheLatestJudgment() async throws {
        let store = try await store()
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "uk", expression: "кни́жка"), now: start)
        _ = try await store.setVocabularyJudgment(.unfamiliar, for: .init(language: "uk", expression: "книжка"),
                                                  now: start.addingTimeInterval(1))
        for _ in 0..<3 {
            #expect(try await store.vocabularySnapshot(language: "uk").state(of: "книжка") == .unfamiliar)
        }
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "uk", expression: "кни́жка"),
                                                  now: start.addingTimeInterval(2))
        #expect(try await store.vocabularySnapshot(language: "uk").state(of: "книжка") == .known)
    }

    @Test func snapshotVersionsAreScopedToTheirLanguage() async throws {
        let store = try await store()
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "uk", expression: "так"))
        let ukrainian = try await store.vocabularySnapshot(language: "uk").version
        let russian = try await store.vocabularySnapshot(language: "ru").version
        #expect(ukrainian != russian)
        _ = try await store.setVocabularyJudgment(.known, for: .init(language: "ru", expression: "да"))
        #expect(try await store.vocabularySnapshot(language: "uk").version == ukrainian)
    }

    @Test func undoingABatchRestoresWhereAJudgmentCameFrom() async throws {
        let store = try await store()
        let term = VocabularyTerm(language: "es", expression: "laguna")
        let set = try await matureSet(store, term: term, sentence: "La laguna está cerca de la casa.")
        #expect(try await store.deleteItem(id: set.item, now: start.addingTimeInterval(60 * 86_400)))
        let batch = UUID()
        _ = try await store.setVocabularyJudgments([.init(term: term, judgment: .ignored)], batchID: batch,
                                                   now: start.addingTimeInterval(61 * 86_400))
        _ = try await store.undoVocabularyBatch(batch, now: start.addingTimeInterval(62 * 86_400))
        let status = try #require(try await store.vocabularyStatuses(language: "es").first)
        #expect(status.judgment == .known && status.origin == .archivedReviews)
    }

    // MARK: 3 Durable evidence

    @Test func suspendingAMatureSetKeepsTheWordKnownButNotLearning() async throws {
        let store = try await store()
        let term = VocabularyTerm(language: "es", expression: "laguna")
        let set = try await matureSet(store, term: term, sentence: "La laguna está cerca de la casa.")
        #expect(try await store.vocabularyStatuses(language: "es").first?.isKnown == true)
        let saved = try #require(try await store.fetchItem(id: set.item))
        for card in CardGenerator.cards(for: saved.item, type: saved.itemType, now: start, deterministicIDs: true) {
            try await store.setCardSuspended(id: card.id, isSuspended: true)
        }
        let status = try #require(try await store.vocabularyStatuses(language: "es").first)
        #expect(status.isKnown && !status.hasCards && status.state == .known)
    }

    @Test func deletingAMatureSetArchivesWhatItsReviewsShowed() async throws {
        let store = try await store()
        let term = VocabularyTerm(language: "es", expression: "laguna")
        let mature = try await matureSet(store, term: term, sentence: "La laguna está cerca de la casa.")
        let fresh = try await store.createVocabularySet(.init(term: .init(language: "es", expression: "río"), meaning: "river",
                                                              meaningLanguage: "en", sentence: "El río es largo."), now: start)
        #expect(try await store.deleteItem(id: mature.item, now: start.addingTimeInterval(60 * 86_400)))
        #expect(try await store.deleteItem(id: fresh, now: start.addingTimeInterval(60 * 86_400)))
        let statuses = try await store.vocabularyStatuses(language: "es")
        #expect(statuses.map(\.term.expression) == ["laguna"])
        #expect(statuses.first?.judgment == .known && statuses.first?.origin == .archivedReviews)
    }
}
