import Foundation
import Darwin
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Testing
@testable import NeoAnkiFeatures

private struct UnavailableContextGenerator: ContextGenerating {
    func availability(language: String) async -> ContextCapability { .unavailable("Unsupported language") }
    func examples(for target: ContextTarget, count: Int, excluding: [String], simpler: Bool) async throws -> [ContextExample] {
        Issue.record("An unavailable generator must never be called"); return []
    }
}
private actor FixtureContextGenerator: ContextGenerating {
    var sequence = 0
    func availability(language: String) async -> ContextCapability { .available }
    func examples(for target: ContextTarget, count: Int, excluding: [String], simpler: Bool) async throws -> [ContextExample] {
        (0..<count).map { _ in
            sequence += 1
            let sentence = "Please \(target.expression) the cost of option \(sequence)."
            return ContextExample(sentence: sentence, spans: ContextOccurrences.find(target: target, in: sentence).spans,
                meaning: "consider the cost of option \(sequence)", language: target.language,
                provenance: .init(origin: .generated, sourceName: "Fixture"))
        }
    }
}
private actor DelayedContextGenerator: ContextGenerating {
    private var pending: CheckedContinuation<[ContextExample], Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func availability(language: String) async -> ContextCapability { .available }
    func examples(for target: ContextTarget, count: Int, excluding: [String], simpler: Bool) async throws -> [ContextExample] {
        await withCheckedContinuation { continuation in pending = continuation; waiter?.resume(); waiter = nil }
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func complete(_ examples: [ContextExample]) { pending?.resume(returning: examples); pending = nil }
}
private struct UnavailableContextSpeech: ContextSpeechSynthesizing {
    func availability(language: String) async -> ContextCapability { .unavailable("No installed voice") }
    func audio(text: String, language: String) async throws -> ContextSpeechAsset { throw ContextAuthoringError.message("No voice") }
}

private func contextWAV() -> Data {
    let payload = Data(repeating: 0, count: 16_000)
    var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    append(UInt32(payload.count + 36)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
    append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000))
    append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(payload.count)); data.append(payload)
    return data
}

@MainActor private final class ContextFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-tests-\(UUID())")
    let repository: SQLiteLibraryRepository
    let deck: Deck
    let model: LearnInContextModel
    init(generator: any ContextGenerating = UnavailableContextGenerator(), onSaved: @escaping @MainActor () async -> Void = {}) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await repository.bootstrap()
        deck = try await repository.createDeck(Deck(name: "Expressions"))
        model = LearnInContextModel(library: repository, rootURL: root.appendingPathComponent("packs"),
                                   generator: generator, speech: UnavailableContextSpeech(), onSaved: onSaved)
        await model.start(deckID: deck.id)
    }
    func cleanup() { model.cancel(); try? FileManager.default.removeItem(at: root) }
    func example(_ sentence: String = "We take into account the cost.") -> ContextExample {
        .init(sentence: sentence, spans: ContextOccurrences.find(target: .init(expression: "take into account", language: "en"), in: sentence).spans,
              provenance: .init(origin: .manual, sourceName: "Fixture"))
    }
    func prepare() {
        model.draft.target = .init(expression: "take into account", language: "en", meaning: "consider when deciding")
        model.draft.examples = [example()]
    }
}

@Suite struct LearnInContextTests {
@Test func contextPackScalarRangesConvertToCharactersWithoutSplittingGraphemes() {
    let sentence = "👩🏽‍💻 cafe\u{301} is open."
    let start = sentence.unicodeScalars.firstIndex(of: "c")!
    let target = ExampleTarget(exactText: "cafe\u{301}", scalarRange: .init(location: sentence.unicodeScalars.distance(from: sentence.unicodeScalars.startIndex, to: start), length: 5))
    let spans = ContextOccurrences.fromPack(target, text: sentence)
    #expect(spans == [.init(start: 2, length: 4)])
    #expect(ContextOccurrences.validated(spans, in: sentence))
    #expect(ContextOccurrences.fromPack(.init(exactText: "e", scalarRange: .init(location: 10, length: 1)), text: sentence).isEmpty)
    #expect(!ContextOccurrences.validated([.init(start: 0, length: Int.max)], in: sentence))
}

@Test func contextFindsSeparatedAndInflectedPhrasesAsCandidates() {
    let target = ContextTarget(expression: "take off", language: "en", meaning: "remove clothing")
    let match = ContextOccurrences.find(target: target, in: "She took her coat off.")
    #expect(match.uncertain)
    #expect(match.spans == [.init(start: 4, length: 4), .init(start: 18, length: 3)])
    let spans = ContextOccurrences.richText("She took her coat off.", spans: match.spans)
    #expect(spans.filter { $0.styles.contains(.bold) }.map(\.text) == ["took", "off"])
    #expect(ContextOccurrences.find(target: .init(expression: "art", language: "en"), in: "The party started.").spans.isEmpty)
    #expect(!ContextOccurrences.find(target: .init(expression: "学校", language: "ja"), in: "毎日学校へ行きます。").spans.isEmpty)
}

@Test func contextSubtitleParserJoinsCuesAndPreservesTimes() throws {
    let text = "WEBVTT\n\n00:01.000 --> 00:02.000\nWe took the cost\n\n00:02.100 --> 00:03.500 align:start\n<i>into account.</i>\n\n00:05.000 --> 00:06.000\nNext sentence.\n"
    let segments = try ContextSubtitles.parse(text)
    #expect(segments.count == 2)
    #expect(segments[0].text == "We took the cost into account.")
    #expect(segments[0].start == 1 && segments[0].end == 3.5)
    #expect(throws: (any Error).self) { try ContextSubtitles.parse("1\n00:00:03,000 --> 00:00:01,000\nWrong.\n") }
}

@Test @MainActor func contextBatchSavesIndependentCardsAndSurvivesRestart() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare()
    fixture.model.draft.examples.append(fixture.example("Please take into account my schedule."))
    fixture.model.draft.cloze = true
    #expect(fixture.model.cardCount == 4)
    await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
    let rows = try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "")
    #expect(rows.count == 2)
    let due = try await fixture.repository.dueCards(scope: .deck(fixture.deck.id), asOf: .now, limit: nil)
    #expect(due.count == 1)
    let generated = try await fixture.repository.cards()
    #expect(generated.count == 4)
    #expect(Set(generated.map(\.id)).count == 4)
    #expect(Set(due.compactMap { card -> String? in
        if case let .text(value, _)? = card.item.value(for: ContextExamplePreset.group.id) { return value }; return nil
    }).count == 1)
    let cloze = try #require(ContextExamplePreset.itemType.templates.first { $0.interaction == .cloze })
    #expect(generated.contains { $0.templateID == cloze.id })
    #expect(cloze.components.filter { $0.source == .field(ContextExamplePreset.audio.id) }.allSatisfy { $0.purpose == .expectedAnswer })
    fixture.prepare()
    await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
    #expect(try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "").count == 3)
    #expect(ContextExamplePreset.itemType == ContextExamplePreset.itemType)
}

@Test @MainActor func contextDraftRestoresEditsAndUncertainExamplesCannotSave() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare()
    fixture.model.draft.examples[0].needsMeaningCheck = true
    fixture.model.checkpoint()
    let restored = LearnInContextModel(library: fixture.repository, rootURL: fixture.root.appendingPathComponent("packs"),
                                      generator: UnavailableContextGenerator(), speech: UnavailableContextSpeech())
    await restored.start()
    #expect(restored.draft == fixture.model.draft)
    #expect(!restored.canSave)
    restored.confirmExample(restored.draft.examples[0].id)
    #expect(restored.canSave)
}

@Test @MainActor func contextMoreExamplesAppendsWithoutReplacingManualEdits() async throws {
    let fixture = try await ContextFixture(generator: FixtureContextGenerator())
    defer { fixture.cleanup() }
    fixture.prepare()
    fixture.model.draft.examples[0].isEdited = true
    let original = fixture.model.draft.examples[0]
    fixture.model.moreExamples()
    await fixture.model.waitForWork()
    #expect(fixture.model.draft.examples.count == 4)
    #expect(fixture.model.draft.examples[0] == original)
    #expect(Set(fixture.model.draft.examples.map { ContextOccurrences.key($0.sentence) }).count == 4)
}

@Test @MainActor func contextSaveIsIdempotentAfterAnInterruptedCommitReceipt() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare()
    let snapshot = fixture.model.draft
    await fixture.model.save()
    fixture.model.draft = snapshot
    await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
    #expect(try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "").count == 1)
}

@Test @MainActor func contextUndoRefusesToDeleteEditedItems() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare(); await fixture.model.save()
    let id = try #require(fixture.model.lastSavedIDs.first)
    var item = try #require(try await fixture.repository.item(id: id)?.item)
    item.tags.append("edited")
    _ = try await fixture.repository.updateItem(item, asOf: .now)
    await fixture.model.undoSave()
    #expect(fixture.model.errorMessage != nil)
    #expect(try await fixture.repository.item(id: id)?.item == item)
}

@Test @MainActor func contextUndoDeletesOnlyItsUnstudiedBatch() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare(); await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
    await fixture.model.undoSave()
    #expect(fixture.model.errorMessage == nil)
    #expect(try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "").isEmpty)
}

@Test @MainActor func contextUnsupportedLanguageKeepsManualAuthoringAvailable() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.model.draft.target = .init(expression: "брати до уваги", language: "uk", meaning: "consider")
    await fixture.model.refreshCapabilities()
    fixture.model.findExamples(); await fixture.model.waitForWork()
    #expect(fixture.model.errorMessage != nil)
    fixture.model.draft.sourceSentence = "Потрібно брати до уваги погоду."
    fixture.model.addManualExample()
    let id = try #require(fixture.model.draft.examples.last?.id)
    fixture.model.confirmExample(id)
    await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
}

@Test func contextSourceImportAndRemovalPreserveSavedClipInput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-sources-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("lesson.wav")
    try contextWAV().write(to: original)
    let library = ContextSourceLibrary(rootURL: root.appendingPathComponent("sources"))
    let source = try await library.importMedia(original, language: "en", subtitleText: "1\n00:00:01,000 --> 00:00:03,000\nWe take into account the cost.\n")
    try FileManager.default.removeItem(at: original)
    let results = try await library.examples(for: .init(expression: "take into account", language: "en", meaning: "consider"), limit: 3)
    #expect(results.count == 1 && results[0].needsMeaningCheck && !results[0].isSelected)
    #expect(FileManager.default.fileExists(atPath: try await library.mediaURL(for: source).path))
    #expect(results[0].clipStart == 1 && results[0].clipEnd == 3)
    try await library.remove(source)
    #expect(try await library.sources().isEmpty)
}

@Test func contextJapaneseSubstringIsNotAnAuthoritativeWordMatch() {
    #expect(ContextOccurrences.find(target: .init(expression: "学", language: "ja"), in: "学校へ行きます。").spans.isEmpty)
    #expect(!ContextOccurrences.find(target: .init(expression: "学校", language: "ja"), in: "学校へ行きます。").spans.isEmpty)
}

@Test func contextClozeConcealsEveryEquivalentOccurrence() {
    let target = ContextTarget(expression: "take off", language: "en", meaning: "remove clothing")
    let text = "I take off my coat, and you take off yours."
    let spans = ContextOccurrences.find(target: target, in: text).spans
    #expect(spans.count == 2)
    let example = ContextExample(sentence: text, spans: Array(spans.prefix(1)), provenance: .init(origin: .manual, sourceName: "Fixture"))
    #expect(ContextOccurrences.clozeSpans(for: example, target: target) == spans)
}

@Test @MainActor func contextExistingItemEntryDoesNotOverwriteAnotherRecoverableDraft() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare(); fixture.model.checkpoint()
    let original = fixture.model.draft
    let seeded = LearnInContextModel(library: fixture.repository, rootURL: fixture.root.appendingPathComponent("packs"),
                                    generator: UnavailableContextGenerator(), speech: UnavailableContextSpeech())
    await seeded.start(deckID: fixture.deck.id, expression: "give up")
    seeded.draft.target.meaning = "stop trying"; seeded.checkpoint()
    let restored = LearnInContextModel(library: fixture.repository, rootURL: fixture.root.appendingPathComponent("packs"),
                                      generator: UnavailableContextGenerator(), speech: UnavailableContextSpeech())
    await restored.start()
    #expect(restored.draft == original)
    await seeded.start(deckID: fixture.deck.id, expression: "give up")
    #expect(seeded.draft.target.meaning == "stop trying")
}

@Test @MainActor func contextEditedRetryRemainsRecoverableInsteadOfDiscardingChanges() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare(); let snapshot = fixture.model.draft
    await fixture.model.save()
    fixture.model.draft = snapshot
    fixture.model.draft.examples[0].usageNote = "A new manual note after recovery."
    await fixture.model.save()
    #expect(fixture.model.errorMessage?.contains("different content") == true)
    #expect(fixture.model.draft.examples[0].usageNote == "A new manual note after recovery.")
    #expect(try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "").count == 1)
}

@Test @MainActor func contextObsoleteGenerationCannotAttachToAnotherExpression() async throws {
    let generator = DelayedContextGenerator()
    let fixture = try await ContextFixture(generator: generator)
    defer { fixture.cleanup() }
    fixture.prepare(); fixture.model.draft.examples = []
    fixture.model.findExamples()
    await generator.waitUntilRequested()
    let obsolete = fixture.model.cancel()
    fixture.model.draft.target = .init(expression: "give up", language: "en", meaning: "stop trying")
    await generator.complete([fixture.example()])
    await obsolete?.value
    #expect(fixture.model.draft.examples.isEmpty)
    #expect(fixture.model.draft.target.expression == "give up")
}

@Test @MainActor func contextRememberedLanguageAlsoAppliesToNewExistingItemDrafts() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.model.draft.target.language = "uk"; fixture.model.checkpoint()
    let model = LearnInContextModel(library: fixture.repository, rootURL: fixture.root.appendingPathComponent("packs"),
                                   generator: UnavailableContextGenerator(), speech: UnavailableContextSpeech())
    await model.start(expression: "брати до уваги")
    #expect(model.draft.target.language == "uk" && model.draft.deckID == fixture.deck.id)
}

@Test @MainActor func contextCommittedSaveDoesNotWaitForDevicePublicationPermission() async throws {
    let gate = DelayedContextGenerator()
    let fixture = try await ContextFixture(onSaved: {
        _ = try? await gate.examples(for: .init(expression: "", language: "en"), count: 1, excluding: [], simpler: false)
    })
    defer { fixture.cleanup() }
    fixture.prepare(); await fixture.model.save()
    await gate.waitUntilRequested()
    #expect(!fixture.model.isSaving)
    #expect(fixture.model.successMessage == "Added 1 card to Expressions.")
    #expect(fixture.model.lastSavedIDs.count == 1)
    await gate.complete([])
}

@Test func contextChangingSentenceInvalidatesOnlyUnchangedGeneratedSpeech() throws {
    let originalSentence = "We take into account the cost."
    let metadata = SavedContextMetadata(groupID: UUID(), target: .init(expression: "take into account", language: "en", meaning: "consider"),
        spans: [.init(start: 3, length: 17)], provenance: .init(origin: .generated, sourceName: "Fixture"),
        clipStart: nil, clipEnd: nil, voiceID: "fixture", speechText: originalSentence)
    let audio = MediaRef(kind: .audio, assetHash: String(repeating: "a", count: 64), fileExtension: "caf")
    let original = Item(itemTypeID: ContextExamplePreset.typeID, fields: [
        .init(fieldID: ContextExamplePreset.context.id, value: .rich([Span(originalSentence)])),
        .init(fieldID: ContextExamplePreset.audio.id, value: .media(audio)),
        .init(fieldID: ContextExamplePreset.metadata.id, value: .text(String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)))
    ])
    var edited = original
    edited.fields[0].value = .rich([Span("Please take into account my schedule.")])
    let reconciled = ContextDerivedContent.invalidatingSpeech(in: edited, original: original, type: ContextExamplePreset.itemType)
    #expect(reconciled.isFieldEmpty(ContextExamplePreset.audio.id))
    #expect(ContextDerivedContent.invalidatingSpeech(in: original, original: original, type: ContextExamplePreset.itemType) == original)
    var replacement = edited
    replacement.fields[1].value = .media(MediaRef(kind: .audio, assetHash: String(repeating: "b", count: 64), fileExtension: "caf"))
    let preserved = ContextDerivedContent.invalidatingSpeech(in: replacement, original: original, type: ContextExamplePreset.itemType)
    #expect(preserved.value(for: ContextExamplePreset.audio.id) == replacement.value(for: ContextExamplePreset.audio.id))
    guard case let .text(json, _)? = preserved.value(for: ContextExamplePreset.metadata.id) else {
        Issue.record("Context metadata was lost"); return
    }
    let updatedMetadata = try JSONDecoder().decode(SavedContextMetadata.self, from: Data(json.utf8))
    #expect(updatedMetadata.voiceID == nil && updatedMetadata.speechText == nil)
}

@Test func contextTranscriptSaveRejectsAStaleCorrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-revision-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = ContextSourceLibrary(rootURL: root)
    let original = ContextSource(name: "Lesson", language: "en", filename: "lesson.wav", kind: .audio,
                                 segments: [.init(text: "First passage.", start: 0, end: 1)])
    try await library.save(original)
    var progressed = original
    progressed.segments.append(.init(text: "Second passage.", start: 1, end: 2))
    try await library.save(progressed, replacing: original)
    var stale = original; stale.segments[0].text = "Corrected first passage."
    await #expect(throws: (any Error).self) { try await library.save(stale, replacing: original) }
    #expect(try await library.sources().first == progressed)
}

@Test @MainActor func contextRelatedCardsAreSeparatedWithoutChangingOtherSchedules() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare()
    fixture.model.draft.examples += [fixture.example("Please take into account the weather."), fixture.example("They take into account my schedule.")]
    await fixture.model.save()
    let field = FieldDef(name: "Question", type: .text, isRequired: true)
    let answer = FieldDef(name: "Answer", type: .text, isRequired: true)
    let type = ItemType(name: "Other", fields: [field, answer], templates: [
        Template(name: "Recall", prompt: .init(slots: [.init(source: .field(field.id))]), answer: .init(slots: [.init(source: .field(answer.id))]),
                 interaction: .reveal, skill: .init(input: .text, output: .text, operation: .recall))
    ])
    _ = try await fixture.repository.createItemType(type)
    let other = Item(itemTypeID: type.id, fields: [.init(fieldID: field.id, value: .text("Other question")), .init(fieldID: answer.id, value: .text("Other answer"))], deckID: fixture.deck.id)
    _ = try await fixture.repository.createItem(other, asOf: .now)
    let before = try await fixture.repository.dueCards(scope: .deck(fixture.deck.id), asOf: .now, limit: nil)
    let otherMemory = try #require(before.first { $0.item.id == other.id }?.card.memory)
    let study = StudyFeatureModel(library: fixture.repository, scope: .deck(fixture.deck.id), title: "Contexts")
    await study.start()
    #expect(study.currentCard?.item.id != other.id)
    await study.grade(.good)
    #expect(study.currentCard?.item.id == other.id)
    #expect(study.currentCard?.card.memory == otherMemory)
}

@Test @MainActor func contextClipPersistsAfterSourceRemovalAndPortableRoundTrip() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.prepare()
    let sourceURL = fixture.root.appendingPathComponent("recording.wav")
    try contextWAV().write(to: sourceURL)
    fixture.model.draft.examples[0].mediaURL = sourceURL
    fixture.model.draft.examples[0].mediaKind = .audio
    fixture.model.draft.examples[0].clipStart = 0.1
    fixture.model.draft.examples[0].clipEnd = 0.5
    fixture.model.draft.listening = true
    await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
    let id = try #require(fixture.model.lastSavedIDs.first)
    let item = try #require(try await fixture.repository.item(id: id)?.item)
    let reference = try #require(item.value(for: ContextExamplePreset.audio.id)?.mediaReference)
    try FileManager.default.removeItem(at: sourceURL)
    let mediaStore = try #require(await fixture.repository.mediaStore())
    let savedURL = try await mediaStore.resolve(reference)
    #expect(FileManager.default.fileExists(atPath: savedURL.path))
    let bundle = fixture.root.appendingPathComponent("contexts.neodeck")
    try await fixture.repository.exportPortableDeck(id: fixture.deck.id, to: bundle)
    let imported = try SQLiteLibraryRepository(databaseURL: fixture.root.appendingPathComponent("imported.sqlite"))
    try await imported.bootstrap()
    _ = try await imported.importPortableDeck(from: bundle, conflictResolution: .useMatchingSchema)
    let rows = try await imported.items(scope: .allDecks, sort: .createdAscending, search: "")
    #expect(rows.count == 1)
    let importedRecord = try #require(try await imported.item(id: rows[0].id))
    let roundTrip = importedRecord.item
    let metadataField = try #require(importedRecord.itemType.fields.first { $0.name == "Context provenance" })
    let audioField = try #require(importedRecord.itemType.fields.first { $0.name == "Audio" })
    #expect(roundTrip.value(for: metadataField.id) == item.value(for: ContextExamplePreset.metadata.id))
    #expect(roundTrip.value(for: audioField.id)?.mediaReference != nil)
    #expect(SavedContextMetadata.groupID(in: roundTrip) == SavedContextMetadata.groupID(in: item))
}

@Test @MainActor func contextDictionarySensesBecomeExamplesWithoutAskingForMeaning() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    let entry = LexicalEntry(id: "take-off", language: "en", canonicalForm: .init(text: .init("take off", language: "en")), senses: [
        .init(id: "remove", definitions: [.init(text: .init("remove clothing", language: "en"))], examples: [.init(text: .init("Please take off your coat.", language: "en"))]),
        .init(id: "flight", definitions: [.init(text: .init("leave the ground", language: "en"))], examples: [.init(text: .init("The planes take off at noon.", language: "en"))])
    ])
    let jsonl = fixture.root.appendingPathComponent("lexicon.jsonl")
    try (JSONEncoder().encode(entry) + Data([10])).write(to: jsonl)
    let pack = fixture.root.appendingPathComponent("lexicon.neovocab")
    try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: pack,
        descriptor: .init(id: "expressions", title: "Expression fixtures", languages: ["en"], capabilities: [.lexicon, .corpus],
                          provenance: .init(sourceID: "tatoeba", sourceName: "Fixture Source", attribution: "Fixture Author", license: "CC BY 4.0")))
    _ = try await InstalledVocabularyPackStore(rootURL: fixture.root.appendingPathComponent("packs")).install(from: pack)
    await fixture.model.start(deckID: fixture.deck.id)
    fixture.model.draft.target.expression = "take off"
    fixture.model.findExamples(); await fixture.model.waitForWork()
    #expect(fixture.model.meanings.count == 2)
    #expect(Set(fixture.model.draft.examples.map(\.sentence)) == ["Please take off your coat.", "The planes take off at noon."])
    #expect(Set(fixture.model.draft.examples.compactMap(\.meaning)) == ["remove clothing", "leave the ground"])
    #expect(fixture.model.draft.examples.first?.provenance.license == "CC BY 4.0")
    #expect(fixture.model.draft.examples.first?.provenance.inheritedSources?.first?.attribution == "Fixture Author")
    #expect(fixture.model.draft.examples.allSatisfy { $0.provenance.origin == .corpus })
    #expect(fixture.model.canSave)
}

@Test @MainActor func contextPhraseAloneGeneratesAndSavesEachExamplesOwnMeaning() async throws {
    let fixture = try await ContextFixture(generator: FixtureContextGenerator())
    defer { fixture.cleanup() }
    fixture.model.draft.target.expression = "take into account"
    fixture.model.findExamples(); await fixture.model.waitForWork()
    #expect(fixture.model.errorMessage == nil)
    #expect(fixture.model.draft.target.meaning.isEmpty)
    #expect(fixture.model.selectedExamples.count == 3)
    #expect(fixture.model.canSave)
    let expected = Set(fixture.model.selectedExamples.compactMap(\.meaning))
    await fixture.model.save()
    #expect(fixture.model.errorMessage == nil)
    let items = try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "")
    #expect(items.count == 3)
    var actual = Set<String>()
    for summary in items {
        let item = try #require(try await fixture.repository.item(id: summary.id)?.item)
        if case let .text(meaning, _)? = item.value(for: ContextExamplePreset.meaning.id) { actual.insert(meaning) }
        let record = try #require(try await fixture.repository.item(id: summary.id))
        #expect(CardGenerator.cards(for: item, type: record.itemType).count == 1)
    }
    #expect(actual == expected)
    await fixture.model.undoSave()
    #expect(try await fixture.repository.items(scope: .deck(fixture.deck.id), sort: .createdAscending, search: "").isEmpty)
}

@Test @MainActor func contextCommittingUnchangedInputDoesNotCancelItsRequest() async throws {
    let generator = DelayedContextGenerator()
    let fixture = try await ContextFixture(generator: generator)
    defer { fixture.cleanup() }
    fixture.prepare(); fixture.model.draft.examples = []
    fixture.model.findExamples()
    await generator.waitUntilRequested()
    fixture.model.updateExpression("take into account")
    #expect(fixture.model.isWorking)
    await generator.complete([fixture.example()])
    await fixture.model.waitForWork()
    #expect(fixture.model.selectedExamples.count == 1)
    #expect(fixture.model.canSave)
    fixture.model.updateExpression("take off")
    #expect(fixture.model.draft.examples.isEmpty && fixture.model.draft.target.meaning.isEmpty)
}

@Test @MainActor func contextPhraseAloneWithoutResourcesExplainsFailure() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.model.draft.target.expression = "bogged down"
    fixture.model.findExamples(); await fixture.model.waitForWork()
    #expect(fixture.model.errorMessage == "Unsupported language")
    #expect(!fixture.model.isWorking)
    #expect(fixture.model.status == nil)
    #expect(!fixture.model.canSave)
}

@Test @MainActor func contextOldDraftPracticeSettingsDoNotLeakIntoMinimalCapture() async throws {
    let fixture = try await ContextFixture()
    defer { fixture.cleanup() }
    fixture.model.draft.cloze = true; fixture.model.draft.listening = true; fixture.model.draft.speech = false
    fixture.model.checkpoint()
    await fixture.model.start()
    #expect(!fixture.model.draft.cloze && !fixture.model.draft.listening && fixture.model.draft.speech)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NEOANKI_CONTEXT_LIVE_EVALUATION"] == "1"))
@MainActor func contextAppleLiveCapabilityAndLatencyEvaluation() async throws {
    let generator = AppleContextGenerator(), clock = ContinuousClock()
    let capability = await generator.availability(language: "en")
    if let reason = capability.reason { print("CONTEXT_EVAL generation_unavailable=\(reason)") }
    else {
        let fixture = try await ContextFixture(generator: generator)
        defer { fixture.cleanup() }
        fixture.model.draft.target.expression = "bogged down"
        fixture.model.findExamples(); await fixture.model.waitForWork()
        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.model.selectedExamples.count == 3)
        #expect(fixture.model.canSave)
        #expect(fixture.model.selectedExamples.allSatisfy { !($0.meaning ?? "").isEmpty })
        await fixture.model.save()
        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.model.lastSavedIDs.count == 3)
        for attempt in 1...2 {
            let started = clock.now
            let examples = try await generator.examples(for: .init(expression: "take into account", language: "en", meaning: "consider when deciding"), count: 3, excluding: [], simpler: false)
            #expect(!examples.isEmpty)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("CONTEXT_EVAL attempt=\(attempt) elapsed=\(started.duration(to: clock.now)) valid_examples=\(examples.count) runner_peak_resident_bytes=\(usage.ru_maxrss)")
        }
    }
    let speech = AppleContextSpeech()
    if let reason = await speech.availability(language: "en").reason { print("CONTEXT_EVAL speech_unavailable=\(reason)") }
    else {
        let started = clock.now
        let asset = try await speech.audio(text: "Please take the delivery time into account.", language: "en")
        #expect(!asset.data.isEmpty)
        print("CONTEXT_EVAL speech_elapsed=\(started.duration(to: clock.now)) bytes=\(asset.data.count) voice=\(asset.voiceID)")
        let transcription = await ContextTranscription.availability(language: "en")
        if let reason = transcription.reason { print("CONTEXT_EVAL transcription_unavailable=\(reason)") }
        else {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-live-transcription-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("sentence.caf"); try asset.data.write(to: url)
            let library = ContextSourceLibrary(rootURL: root.appendingPathComponent("sources"))
            let source = try await library.importMedia(url, language: "en")
            let started = clock.now
            try await ContextTranscription.run(source: source, library: library)
            let saved = try #require(try await library.sources().first)
            #expect(saved.transcriptionComplete && !saved.segments.isEmpty)
            print("CONTEXT_EVAL transcription_elapsed=\(started.duration(to: clock.now)) finalized_passages=\(saved.segments.count)")
        }
    }
}
}
