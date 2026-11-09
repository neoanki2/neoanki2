import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Testing
@testable import NeoAnkiFeatures

@MainActor private final class CaptureFixture {
    let root: URL
    let repository: SQLiteLibraryRepository
    let packs: URL
    let store: FileVocabularyDeckConfigurationStore
    let word = FieldDef(name: "Word", type: .text, isRequired: true)
    let answer = FieldDef(name: "Answer", type: .richText, isRequired: true)
    let phrase = FieldDef(name: "Phrase", type: .text, isRequired: false)
    let type: ItemType
    let deck: Deck
    let otherDeck: Deck
    var model: WordCaptureModel!
    init(entries: [LexicalEntry]? = nil, requiredPhrase: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        var phrase = self.phrase
        phrase.isRequired = requiredPhrase
        type = ItemType(name: "Vocabulary", fields: [word, answer, phrase], templates: [
            Template(name: "Recall", prompt: Side(slots: [Slot(source: .field(word.id))]),
                     answer: Side(slots: [Slot(source: .field(answer.id))]), interaction: .reveal,
                     skill: Skill(input: .text, output: .text, operation: .recall))
        ])
        _ = try await repository.createItemType(type)
        deck = try await repository.createDeck(Deck(name: "Words"))
        otherDeck = try await repository.createDeck(Deck(name: "Other words"))
        packs = root.appendingPathComponent("packs")
        store = FileVocabularyDeckConfigurationStore(rootURL: root.appendingPathComponent("preferences"))
        let entries = entries ?? [Self.entry()]
        for id in ["first", "second"] {
            let jsonl = root.appendingPathComponent("\(id).jsonl")
            try entries.reduce(into: Data()) { data, entry in data += try JSONEncoder().encode(entry) + Data([10]) }.write(to: jsonl)
            let pack = root.appendingPathComponent("\(id).neovocab")
            try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: pack,
                descriptor: .init(id: id, title: id, languages: ["uk"], capabilities: [.lexicon, .pronunciation]))
            _ = try await InstalledVocabularyPackStore(rootURL: packs).install(from: pack)
        }
        model = makeModel()
        await model.start(deckID: deck.id)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func makeModel(delay: Duration = .zero, onSaved: @escaping @MainActor () async -> Void = {}) -> WordCaptureModel {
        WordCaptureModel(library: repository, rootURL: packs, configurationStore: store,
                         lookup: DictionaryLookupModel(delay: delay), onSaved: onSaved)
    }
    func configuration(source: VocabularyFieldSource = .pronunciationText, dictionaryID: String = "first", deckID: UUID? = nil) -> VocabularyDeckConfiguration {
        .init(dictionaryID: dictionaryID, deckID: deckID ?? deck.id, itemTypeID: type.id, bindings: [
            .init(fieldID: word.id, fieldType: .text, source: .typedWord),
            .init(fieldID: answer.id, fieldType: .richText, source: source),
            .init(fieldID: phrase.id, fieldType: .text)
        ])
    }
    func configure(source: VocabularyFieldSource = .pronunciationText) {
        model.selectDictionary("first")
        #expect(model.saveConfiguration(configuration(source: source)))
    }
    static func entry(word: String = "начинка", pronunciations: [Pronunciation]? = nil, senses: [LexicalSense]? = nil) -> LexicalEntry {
        .init(id: word, language: "uk", canonicalForm: .init(text: .init(word, language: "uk")),
              pronunciations: pronunciations ?? [.init(scheme: "source-defined-stress", representations: [.text(.init("НА\u{301}ЧИНКА"))])],
              senses: senses ?? [.init(id: "filling", definitions: [.init(text: .init("Filling.", language: "en"))],
                                      examples: [.init(text: .init("Начинка для пирога.", language: "uk"))])])
    }
}

@Test @MainActor func captureSavesPronunciationAloneAndContinuesWithSamePair() async throws {
    let fixture = try await CaptureFixture(requiredPhrase: true)
    defer { fixture.cleanup() }
    fixture.configure()
    let model = fixture.model!
    model.query = "начинка"
    await model.search()
    #expect(model.text[fixture.answer.id] == "НА\u{301}ЧИНКА")
    #expect(!model.canSave)
    model.setText("Начинка для пирога.", fieldID: fixture.phrase.id)
    #expect(model.canSave)
    await model.save()
    #expect(model.errorMessage == nil)
    let rows = try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "")
    #expect(rows.count == 1)
    let saved = try #require(try await fixture.repository.item(id: rows[0].id)?.item)
    #expect(saved.value(for: fixture.answer.id) == .rich([Span("НА\u{301}ЧИНКА")]))
    #expect(saved.value(for: fixture.phrase.id) == .text("Начинка для пирога."))
    #expect(model.query.isEmpty && model.text.isEmpty && model.focusGeneration == 1)
    #expect(model.deckID == fixture.deck.id && model.dictionaryID == "first")
    #expect(model.successMessage?.contains("Words") == true)
    model.query = "начинка"; await model.search()
    #expect(model.configuration != nil && model.text[fixture.answer.id] == "НА\u{301}ЧИНКА")
}

@Test @MainActor func capturePairPreferencesAreIndependentAndSurviveRelaunchAndRenames() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    fixture.configure()
    let model = fixture.model!
    model.selectDictionary("second")
    #expect(model.deckID == fixture.deck.id && model.configuration == nil)
    #expect(model.saveConfiguration(fixture.configuration(source: .meaning, dictionaryID: "second")))
    model.selectDeck(fixture.otherDeck.id)
    #expect(model.configuration == nil)
    model.selectDictionary("first")
    #expect(model.saveConfiguration(fixture.configuration(source: .example, deckID: fixture.otherDeck.id)))
    model.selectDeck(fixture.deck.id)
    #expect(model.dictionaryID == "second")
    #expect(model.configuration?.bindings[1].source == .meaning)
    model.selectDictionary("first")
    #expect(model.configuration?.bindings[1].source == .pronunciationText)
    #expect(model.deckID == fixture.deck.id)
    var renamed = fixture.deck; renamed.name = "Renamed"
    _ = try await fixture.repository.updateDeck(renamed)
    let relaunched = fixture.makeModel()
    await relaunched.start()
    #expect(relaunched.deckID == fixture.deck.id && relaunched.destinationName == "Renamed")
    #expect(relaunched.configuration == fixture.configuration())
    #expect(relaunched.preferences.configurations.count == 3)
    // Preferences belong to the persistent library identity, not a global last-used record.
    #expect(try fixture.store.load(libraryID: UUID()).configurations.isEmpty)
}

@Test @MainActor func captureRequiresRelevantMeaningAndPronunciationChoices() async throws {
    let entry = CaptureFixture.entry(pronunciations: [
        .init(scheme: "ipa", representations: [.text(.init("one"))], senseIDs: ["first"]),
        .init(scheme: "ipa", representations: [.text(.init("two"))], senseIDs: ["second"])
    ], senses: [
        .init(id: "first", definitions: [.init(text: .init("First meaning"))]),
        .init(id: "second", definitions: [.init(text: .init("Second meaning"))])
    ])
    let fixture = try await CaptureFixture(entries: [entry])
    defer { fixture.cleanup() }
    fixture.configure(source: .meaning)
    let model = fixture.model!
    model.query = "начинка"; await model.search()
    #expect(model.needsChoice(fixture.answer) && !model.canSave)
    let binding = try #require(model.binding(for: fixture.answer.id))
    let choice = try #require(model.choices(for: binding).last)
    model.choose(choice, for: fixture.answer.id)
    #expect(model.canSave && model.text[fixture.answer.id] == "Second meaning")
    let pronunciation = VocabularyFieldBinding(fieldID: UUID(), fieldType: .text, source: .pronunciationText)
    #expect(model.choices(for: pronunciation).map(\.text) == ["two"])
    // A pronunciation-only setup does not force unrelated meaning selection.
    #expect(model.saveConfiguration(fixture.configuration()))
    #expect(!model.canSave) // The two pronunciations now require their own choice.
}

@Test @MainActor func capturePreservesManualEditsAndRejectsStaleQueryResults() async throws {
    let fixture = try await CaptureFixture(entries: [CaptureFixture.entry(), CaptureFixture.entry(word: "інший")])
    defer { fixture.cleanup() }
    let model = fixture.makeModel(delay: .milliseconds(40))
    await model.start(deckID: fixture.deck.id)
    model.selectDictionary("first")
    #expect(model.saveConfiguration(fixture.configuration()))
    model.query = "начинка"; await model.search()
    model.setText("My own answer", fieldID: fixture.answer.id)
    await model.search()
    #expect(model.text[fixture.answer.id] == "My own answer")
    model.query = "нач"
    let old = Task { await model.search() }
    await Task.yield()
    model.query = "інший"
    #expect(model.selectedEntry == nil && !model.canSave)
    old.cancel()
    await model.search(); await old.value
    #expect(model.selectedEntry?.id == "інший")
    #expect(model.text[fixture.word.id] == "інший")
    #expect(model.text[fixture.answer.id] == "My own answer")
    #expect(model.preferences.configurations.first?.bindings[1].source == .pronunciationText)
}

@Test @MainActor func capturePrefixAndMissingEntriesRequireExplicitSelectionOrManualEntry() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    fixture.configure(source: .meaning)
    let model = fixture.model!
    model.query = "нач"; await model.search()
    #expect(model.results.count == 1 && model.selectedEntry == nil && !model.canSave)
    model.selectEntry(try #require(model.results.first))
    #expect(model.canSave)
    model.query = "unknown"; await model.search()
    #expect(model.results.isEmpty && model.selectedEntry == nil && !model.canSave)
    model.enterManually()
    model.setText("A manual definition", fieldID: fixture.answer.id)
    #expect(model.canSave && model.text[fixture.word.id] == "unknown")
}

@Test @MainActor func captureRecognizesChangedSchemasAndMissingPacksWithoutDiscardingConfiguration() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    fixture.configure()
    var changed = fixture.type
    changed.fields.removeLast()
    #expect(fixture.configuration().issue(itemTypes: [changed]) != nil)
    changed = fixture.type; changed.fields[1].type = .number
    #expect(fixture.configuration().issue(itemTypes: [changed]) != nil)
    #expect(fixture.configuration().issue(itemTypes: []) != nil)
    var renamed = fixture.type; renamed.fields[1].name = "Renamed"
    #expect(fixture.configuration().issue(itemTypes: [renamed]) == nil)
    let model = fixture.model!
    model.query = "начинка"; await model.search()
    let installed = try #require(model.selectedPack)
    try FileManager.default.removeItem(at: installed.packageURL)
    let reopened = fixture.makeModel(); await reopened.start()
    #expect(reopened.dictionaryID == "first" && reopened.selectedPack == nil)
    #expect(reopened.configuration != nil && !reopened.canSave)
    #expect(model.configuration != nil)
}

@Test @MainActor func captureSaveFailurePreservesDraftAndRepeatedSaveDoesNotDuplicate() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    fixture.configure()
    let model = fixture.model!
    model.query = "начинка"; await model.search()
    _ = try await fixture.repository.deleteDeck(id: fixture.deck.id)
    await model.save()
    #expect(model.errorMessage != nil && model.query == "начинка")
    #expect(model.text[fixture.answer.id] == "НА\u{301}ЧИНКА")
    _ = try await fixture.repository.createDeck(fixture.deck)
    async let first: Void = model.save()
    async let second: Void = model.save()
    _ = await (first, second)
    let rows = try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "")
    #expect(rows.count == 1 && model.query.isEmpty)
}

@Test @MainActor func captureSupportsArbitrarySchemesFormsLanguagesAndScripts() async throws {
    let entry = LexicalEntry(id: "reading", language: "ja", canonicalForm: .init(text: .init("日本語", language: "ja")),
        forms: [.init(id: "kana", text: .init("にほんご", language: "ja"), kind: "source-reading")],
        pronunciations: [.init(scheme: "source-pinyin-or-other", representations: [.text(.init("にほんご", language: "ja"))])],
        senses: [.init(id: "language", definitions: [.init(text: .init("Japanese", language: "en")), .init(text: .init("اليابانية", language: "ar"))])])
    let fixture = try await CaptureFixture(entries: [entry])
    defer { fixture.cleanup() }
    fixture.configure(source: .meaning)
    let model = fixture.model!
    model.query = "日本語"; await model.search()
    var config = fixture.configuration(source: .meaning)
    config.bindings[1].language = "ar"
    #expect(model.saveConfiguration(config))
    #expect(model.text[fixture.answer.id] == "اليابانية" && model.canSave)
    var binding = VocabularyFieldBinding(fieldID: UUID(), fieldType: .text, source: .form, variant: "source-reading")
    #expect(model.choices(for: binding).first?.text == "にほんご")
    binding.source = .pronunciationText; binding.variant = "source-pinyin-or-other"
    #expect(model.choices(for: binding).first?.text == "にほんご")
    binding.variant = "missing-scheme"
    #expect(model.choices(for: binding).isEmpty)
}

@Test @MainActor func captureCopiesVerifiedDictionaryAudioIntoLibraryMediaAndRetainsFailureDraft() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    let audio = FieldDef(name: "Recording", type: .audio, isRequired: true)
    let type = ItemType(name: "Listen", fields: [fixture.word, audio], templates: [
        Template(name: "Listen", prompt: Side(slots: [Slot(source: .field(fixture.word.id))]),
                 answer: Side(slots: [Slot(source: .field(audio.id))]), interaction: .reveal,
                 skill: Skill(input: .text, output: .audio, operation: .recall))
    ])
    _ = try await fixture.repository.createItemType(type)
    let media = fixture.root.appendingPathComponent("audio-source")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let data = Data("RIFF0000WAVEfixture".utf8)
    try data.write(to: media.appendingPathComponent("word.wav"))
    let entry = CaptureFixture.entry(pronunciations: [
        .init(scheme: "source-recording", representations: [.audio(.init(path: "word.wav", mimeType: "audio/wav"))])
    ])
    let jsonl = fixture.root.appendingPathComponent("audio.jsonl")
    try (JSONEncoder().encode(entry) + Data([10])).write(to: jsonl)
    let pack = fixture.root.appendingPathComponent("audio.neovocab")
    try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: pack,
        descriptor: .init(id: "audio", title: "Audio", languages: ["uk"], capabilities: [.pronunciation]),
        options: .init(mediaDirectoryURL: media))
    _ = try await InstalledVocabularyPackStore(rootURL: fixture.packs).install(from: pack)
    let model = fixture.makeModel(); await model.start(deckID: fixture.deck.id)
    model.selectDictionary("audio")
    let config = VocabularyDeckConfiguration(dictionaryID: "audio", deckID: fixture.deck.id, itemTypeID: type.id, bindings: [
        .init(fieldID: fixture.word.id, fieldType: .text, source: .typedWord),
        .init(fieldID: audio.id, fieldType: .audio, source: .pronunciationAudio, variant: "source-recording")
    ])
    #expect(model.saveConfiguration(config))
    model.query = "начинка"; await model.search()
    #expect(model.canSave)
    await model.save()
    #expect(model.errorMessage == nil)
    let rows = try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "")
    let row = try #require(rows.first)
    let saved = try #require(try await fixture.repository.item(id: row.id)?.item)
    guard case let .media(reference) = saved.value(for: audio.id) else { Issue.record("Audio was not persisted"); return }
    let libraryMedia = try #require(await fixture.repository.mediaStore())
    let mediaURL = try await libraryMedia.resolve(reference)
    #expect(try Data(contentsOf: mediaURL) == data)
    // Pack assets are verified at use; changing one cannot commit corrupt audio.
    model.query = "начинка"; await model.search()
    let installed = try #require(model.selectedPack)
    try Data("tampered".utf8).write(to: installed.packageURL.appendingPathComponent("media/word.wav"))
    await model.save()
    #expect(model.errorMessage != nil && model.query == "начинка")
    #expect(try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "").count == 1)
}

@Test @MainActor func captureRemembersConfiguredDeckOpenedFromContextWithoutChangingSelectors() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    fixture.configure()
    fixture.model.selectDeck(fixture.otherDeck.id)
    fixture.model.selectDictionary("first")
    #expect(fixture.model.saveConfiguration(fixture.configuration(source: .meaning, deckID: fixture.otherDeck.id)))
    fixture.model.selectDeck(fixture.deck.id)
    let contextual = fixture.makeModel(); await contextual.start(deckID: fixture.otherDeck.id)
    #expect(contextual.configuration?.bindings[1].source == .meaning)
    contextual.query = "начинка"; await contextual.search(); await contextual.save()
    let home = fixture.makeModel(); await home.start()
    #expect(home.deckID == fixture.otherDeck.id)
    #expect(home.configuration?.bindings[1].source == .meaning)
    await contextual.search() // Empty-query task after saving must preserve the confirmation.
    #expect(contextual.successMessage != nil)
}

@Test @MainActor func captureDoesNotRequireChoosingAnOptionalAmbiguousExample() async throws {
    var entry = CaptureFixture.entry()
    entry.senses[0].examples.append(.init(text: .init("Ще одна начинка.", language: "uk")))
    let fixture = try await CaptureFixture(entries: [entry])
    defer { fixture.cleanup() }
    fixture.configure()
    var config = fixture.configuration()
    config.bindings[2].source = .example
    #expect(fixture.model.saveConfiguration(config))
    fixture.model.query = "начинка"; await fixture.model.search()
    #expect(fixture.model.needsChoice(fixture.phrase))
    #expect(fixture.model.canSave)
    await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
    let rows = try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "")
    let row = try #require(rows.first)
    let item = try #require(try await fixture.repository.item(id: row.id)?.item)
    #expect(item.value(for: fixture.phrase.id) == .text(""))
}

@Test @MainActor func captureRevalidatesNewlyRequiredFieldsFromLiveSchemaBeforeSaving() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    fixture.configure()
    let model = fixture.model!
    model.query = "начинка"; await model.search()
    #expect(model.canSave)
    var changed = fixture.type
    changed.fields[2].isRequired = true
    _ = try await fixture.repository.updateItemType(changed, asOf: .now)
    await model.save()
    #expect(model.errorMessage?.contains("Phrase") == true)
    #expect(model.requiredFields.contains { $0.id == fixture.phrase.id })
    #expect(!model.canSave && model.query == "начинка")
    model.setText("Начинка для пирога.", fieldID: fixture.phrase.id)
    #expect(model.canSave)
    await model.save()
    #expect(model.errorMessage == nil && model.query.isEmpty)
}

@Test @MainActor func captureReinstalledMissingDictionaryResumesRetainedQueryAndSetup() async throws {
    let fixture = try await CaptureFixture()
    defer { fixture.cleanup() }
    fixture.configure()
    let model = fixture.model!
    model.query = "начинка"; await model.search()
    let installed = try #require(model.selectedPack)
    try FileManager.default.removeItem(at: installed.packageURL)
    try await model.reloadCatalog()
    await model.search()
    #expect(model.selectedPack == nil && !model.canSave)
    let suspendedRequest = model.requestKey
    await model.importDictionary(from: fixture.root.appendingPathComponent("first.neovocab"))
    #expect(model.errorMessage == nil)
    #expect(model.selectedPack != nil && model.configuration == fixture.configuration())
    #expect(model.query == "начинка" && model.requestKey != suspendedRequest)
    await model.search() // The view restarts its lookup task when the request changes.
    #expect(model.canSave && model.text[fixture.answer.id] == "НА\u{301}ЧИНКА")
}

@Test @MainActor func captureCompletesPrefixSelectionsAndKeepsInflectedPronunciationsAligned() async throws {
    let entry = LexicalEntry(id: "run", language: "en",
        canonicalForm: .init(id: "lemma", text: .init("run", language: "en")),
        forms: [.init(id: "participle", text: .init("running", language: "en"), kind: "inflected")],
        pronunciations: [
            .init(scheme: "ipa", representations: [.text(.init("rʌn"))], formIDs: ["lemma"]),
            .init(scheme: "ipa", representations: [.text(.init("rʌnɪŋ"))], formIDs: ["participle"])
        ], senses: [.init(id: "move", definitions: [.init(text: .init("Move quickly."))])])
    let fixture = try await CaptureFixture(entries: [entry])
    defer { fixture.cleanup() }
    fixture.configure()
    let model = fixture.model!
    model.query = "running"; await model.search()
    #expect(model.text[fixture.word.id] == "running")
    #expect(model.text[fixture.answer.id] == "rʌnɪŋ")
    model.query = "ru"; await model.search()
    #expect(model.selectedEntry == nil)
    model.selectEntry(try #require(model.results.first))
    #expect(model.query == "run" && model.text[fixture.word.id] == "run")
    #expect(model.text[fixture.answer.id] == "rʌn")
    await model.search() // The completed query must not lose its explicit entry selection.
    #expect(model.canSave && model.selectedEntry?.id == "run")
}

@Test @MainActor func captureChangingMeaningKeepsAnIndependentFormChoice() async throws {
    var entry = CaptureFixture.entry(senses: [
        .init(id: "one", definitions: [.init(text: .init("One meaning"))]),
        .init(id: "two", definitions: [.init(text: .init("Another meaning"))])
    ])
    entry.forms = [.init(id: "first", text: .init("first form")), .init(id: "second", text: .init("second form"))]
    let fixture = try await CaptureFixture(entries: [entry])
    defer { fixture.cleanup() }
    fixture.configure(source: .meaning)
    var config = fixture.configuration(source: .meaning)
    config.bindings[2].source = .form
    #expect(fixture.model.saveConfiguration(config))
    let model = fixture.model!
    model.query = "начинка"; await model.search()
    let formBinding = try #require(model.binding(for: fixture.phrase.id))
    model.choose(try #require(model.choices(for: formBinding).last), for: fixture.phrase.id)
    let meaningBinding = try #require(model.binding(for: fixture.answer.id))
    model.choose(try #require(model.choices(for: meaningBinding).last), for: fixture.answer.id)
    #expect(model.text[fixture.phrase.id] == "second form")
    #expect(model.text[fixture.answer.id] == "Another meaning")
}
