import Foundation
import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import NeoAnkiVocabularyKit
import Testing
@testable import VocabularyDeckBuilder

@Test func englishFixtureProducesMeaningCardsWithoutLanguageSpecificRules() throws {
    let input = VocabularyDeckInput(
        deckName: "English",
        language: "en",
        form: "bank",
        senses: [
            .init(id: "financial", definition: "A business that keeps and lends money."),
            .init(id: "river", definition: "The land alongside a river."),
        ],
        paradigms: [.formToMeaning, .meaningToForm]
    )

    let cards = try VocabularyDeckGenerator.preview(input: input)

    #expect(cards.count == 4)
    #expect(cards.filter { $0.paradigm == .formToMeaning }.count == 2)
    #expect(cards.filter { $0.paradigm == .meaningToForm }.count == 2)
    #expect(cards.contains { $0.prompt == "The land alongside a river." && $0.answer == "bank" })
}

@Test func arbitraryAnnotatedPronunciationIsPreservedAsGenericText() throws {
    let annotated = "fotogra\u{301}fo"
    let input = VocabularyDeckInput(
        deckName: "Vocabulary",
        language: "es",
        form: "fotografo",
        pronunciations: [
            .init(
                id: "annotated",
                scheme: "orthographic-respelling",
                displayLabel: "Annotated spelling",
                content: .text(annotated)
            ),
        ],
        paradigms: [.formToPronunciation]
    )

    let card = try #require(VocabularyDeckGenerator.preview(input: input).first)
    #expect(card.prompt == "fotografo")
    #expect(card.answer == annotated)
}

@Test func recipeConditionsOnlyGenerateEnabledTemplates() throws {
    let workspace = TestWorkspaceProvider()
    let generated = try VocabularyDeckGenerator.generate(
        input: VocabularyDeckInput(
            destinationDeckID: UUID(),
            deckName: "Selective",
            language: "en",
            form: "swift",
            pronunciations: [
                .init(id: "ipa", scheme: "ipa", displayLabel: "IPA", content: .text("/sw\u{26A}ft/")),
            ],
            senses: [.init(id: "sense", definition: "Moving very fast.")],
            paradigms: [.formToMeaning]
        ),
        workspaceProvider: workspace
    )
    defer { generated.cleanup() }

    let manifest = try String(
        contentsOf: generated.bundleURL.appendingPathComponent(AuthoredDeck.manifestName),
        encoding: .utf8
    )
    #expect(manifest.contains("Form to Meaning"))
    #expect(!manifest.contains("Meaning to Form"))
    #expect(!manifest.contains("Form to Pronunciation"))
    #expect(!manifest.contains("vocabulary-pronunciation-text"))
}

@Test func clozeMarkupUsesExtendedGraphemeOffsets() throws {
    let text = "\u{1F469}\u{1F3FD}\u{200D}\u{1F52C} examines cafe\u{301}."
    let characters = Array(text)
    let target = "cafe\u{301}"
    let start = try #require(characterOffset(of: target, in: text))
    let example = VocabularyExampleSelection(
        id: "unicode",
        text: text,
        targetStart: start,
        targetLength: Array(target).count
    )

    #expect(characters.first.map(String.init) == "\u{1F469}\u{1F3FD}\u{200D}\u{1F52C}")
    #expect(try VocabularyDeckGenerator.clozeMarkup(for: example)
        == "\u{1F469}\u{1F3FD}\u{200D}\u{1F52C} examines {{c1::cafe\u{301}}}.")
}

@Test func scalarRangesConvertToWholeGraphemeOffsets() throws {
    let text = "x e\u{301} \u{1F469}\u{1F3FD}\u{200D}\u{1F52C} y"
    let combining = ExampleTarget(
        exactText: "e\u{301}",
        scalarRange: .init(location: 2, length: 2)
    )
    let emoji = ExampleTarget(
        exactText: "\u{1F469}\u{1F3FD}\u{200D}\u{1F52C}",
        scalarRange: .init(location: 5, length: 4)
    )

    let combiningRange = try LexicalEntryDraftFactory.graphemeRange(
        in: text,
        target: combining,
        exampleID: "combining"
    )
    let emojiRange = try LexicalEntryDraftFactory.graphemeRange(
        in: text,
        target: emoji,
        exampleID: "emoji"
    )

    #expect(combiningRange.start == 2)
    #expect(combiningRange.length == 1)
    #expect(emojiRange.start == 4)
    #expect(emojiRange.length == 1)
}

@Test func scalarRangeInsideCombiningGraphemeIsRejected() {
    let text = "e\u{301}lan"
    let partial = ExampleTarget(
        exactText: "\u{301}",
        scalarRange: .init(location: 1, length: 1)
    )

    #expect(throws: LexicalEntryDraftError.invalidExampleTarget("partial")) {
        try LexicalEntryDraftFactory.graphemeRange(
            in: text,
            target: partial,
            exampleID: "partial"
        )
    }
}

@Test func generatedVocabularyDeckPassesAuthoredDeckValidation() throws {
    let workspace = TestWorkspaceProvider()
    let generated = try VocabularyDeckGenerator.generate(
        input: VocabularyDeckInput(
            destinationDeckID: UUID(),
            deckName: "Generic Vocabulary",
            language: "fr",
            form: "parler",
            pronunciations: [
                .init(id: "ipa", scheme: "ipa", displayLabel: "IPA", content: .text("/pa\u{281}le/")),
            ],
            senses: [
                .init(
                    id: "speak",
                    definition: "Exprimer sa pens\u{E9}e par la parole.",
                    examples: [
                        .init(id: "example", text: "Nous parlons calmement.", targetStart: 5, targetLength: 7),
                    ]
                ),
            ]
        ),
        workspaceProvider: workspace
    )
    defer { generated.cleanup() }

    #expect(AuthoredDeck.validate(at: generated.bundleURL).isEmpty)
}

@Test func clozeRejectsOffsetsThatDoNotIdentifyASurfaceForm() {
    let invalid = VocabularyExampleSelection(
        id: "bad-range",
        text: "short",
        targetStart: 4,
        targetLength: 4
    )

    #expect(throws: VocabularyDeckBuilderError.invalidExample("bad-range")) {
        try VocabularyDeckGenerator.clozeMarkup(for: invalid)
    }
}

@Test func incompatibleSenseSpecificPronunciationCannotGenerateAConflictingCard() {
    let input = VocabularyDeckInput(
        deckName: "Heteronyms",
        language: "en",
        formID: "lemma",
        form: "lead",
        pronunciations: [
            .init(
                id: "verb",
                scheme: "ipa",
                displayLabel: "Verb",
                content: .text("/li\u{2D0}d/"),
                formIDs: ["lemma"],
                senseIDs: ["verb"]
            ),
        ],
        senses: [
            .init(id: "verb", definition: "To guide.", isSelected: true),
            .init(id: "metal", definition: "A heavy metal.", isSelected: true),
        ],
        paradigms: [.formToPronunciation]
    )

    #expect(throws: VocabularyDeckBuilderError.incompatiblePronunciation("verb")) {
        try VocabularyDeckGenerator.preview(input: input)
    }
}

@Test func generatedItemsRetainStructuredProvenanceAndSourceIDs() throws {
    let workspace = TestWorkspaceProvider()
    let generated = try VocabularyDeckGenerator.generate(
        input: VocabularyDeckInput(
            destinationDeckID: UUID(),
            deckName: "Provenance",
            language: "en",
            formID: "lemma",
            form: "bank",
            senses: [
                .init(
                    id: "financial",
                    definition: "A financial institution.",
                    definitionIDs: ["definition-7"],
                    definitionProvenances: [
                        .init(sourceID: "definition-source", attribution: "Definition attribution"),
                    ],
                    provenance: .init(
                        sourceID: "sense-source",
                        recordID: "record-9",
                        attribution: "Sense attribution",
                        license: "CC-BY-SA-4.0",
                        sourceURL: "https://example.invalid/sense"
                    )
                ),
            ],
            paradigms: [.formToMeaning],
            sourceLabel: "Fixture Pack",
            sourceContext: .init(
                packID: "pack.example",
                entryID: "entry-42",
                pack: .init(sourceID: "pack-source", license: "CC0-1.0"),
                entry: .init(sourceID: "entry-source", recordID: "entry-record")
            )
        ),
        workspaceProvider: workspace
    )
    defer { generated.cleanup() }

    let items = try String(
        contentsOf: generated.bundleURL.appendingPathComponent("items/vocabulary.jsonl"),
        encoding: .utf8
    )
    let line = try #require(items.split(separator: "\n").first)
    let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let fields = try #require(object["fields"] as? [String: Any])
    #expect((fields["pack_id"] as? [String: Any])?["text"] as? String == "pack.example")
    #expect((fields["entry_id"] as? [String: Any])?["text"] as? String == "entry-42")
    #expect((fields["sense_id"] as? [String: Any])?["text"] as? String == "financial")
    let provenanceText = try #require((fields["provenance"] as? [String: Any])?["text"] as? String)
    let provenance = try #require(
        JSONSerialization.jsonObject(with: Data(provenanceText.utf8)) as? [String: Any]
    )
    #expect(provenance["definitionIDs"] as? [String] == ["definition-7"])
    #expect((provenance["sense"] as? [String: Any])?["license"] as? String == "CC-BY-SA-4.0")
    #expect((provenance["sense"] as? [String: Any])?["sourceURL"] as? String
        == "https://example.invalid/sense")
    #expect(((provenance["definitions"] as? [[String: Any]])?.first)?["attribution"] as? String
        == "Definition attribution")
}

@Test func generatedPronunciationRetainsFineGrainedProvenance() throws {
    let generated = try VocabularyDeckGenerator.generate(
        input: VocabularyDeckInput(
            destinationDeckID: UUID(),
            deckName: "Pronunciation provenance",
            form: "word",
            pronunciations: [
                .init(
                    id: "ipa",
                    scheme: "ipa",
                    displayLabel: "IPA",
                    content: .text("/wɜːd/"),
                    provenance: .init(
                        sourceID: "pronunciation-source",
                        attribution: "Pronunciation attribution"
                    )
                ),
            ],
            paradigms: [.formToPronunciation]
        ),
        workspaceProvider: TestWorkspaceProvider()
    )
    defer { generated.cleanup() }

    let items = try String(
        contentsOf: generated.bundleURL.appendingPathComponent("items/vocabulary.jsonl"),
        encoding: .utf8
    )
    let line = try #require(items.split(separator: "\n").first)
    let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let fields = try #require(object["fields"] as? [String: Any])
    let provenanceText = try #require((fields["provenance"] as? [String: Any])?["text"] as? String)
    let provenance = try #require(
        JSONSerialization.jsonObject(with: Data(provenanceText.utf8)) as? [String: Any]
    )
    #expect((provenance["pronunciation"] as? [String: Any])?["attribution"] as? String
        == "Pronunciation attribution")
}

@Test func draftFactoryPreservesCanonicalLanguageUniqueIDsAndUnsupportedAudioEvidence() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vocabulary-draft-remediation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("media-source", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false)
    try Data([0x4F, 0x67, 0x67, 0x53]).write(to: media.appendingPathComponent("word.ogg"))

    let entry = LexicalEntry(
        id: "entry",
        language: "en",
        canonicalForm: .init(id: "lemma", text: .init("word", language: "en-Latn")),
        pronunciations: [
            .init(scheme: "ipa", representations: [.text(.init("/w\u{25C}\u{2D0}d/"))]),
            .init(scheme: "respelling", representations: [.text(.init("wurd", language: "en"))]),
            .init(scheme: "recording", representations: [.audio(.init(path: "word.ogg"))]),
        ],
        senses: [
            .init(
                id: "sense",
                definitions: [
                    .init(id: "known", text: .init("Known language", language: "en")),
                    .init(id: "unknown", text: .init("Unknown language")),
                ]
            ),
        ]
    )
    let jsonl = root.appendingPathComponent("entries.jsonl")
    try (try JSONEncoder().encode(entry) + Data([0x0A])).write(to: jsonl)
    let packURL = root.appendingPathComponent("Fixture.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "pack", title: "Pack", languages: ["en"], capabilities: [.lexicon, .pronunciation]),
        options: .init(mediaDirectoryURL: media)
    )
    let pack = try await VocabularyPack.open(at: packURL)
    let input = try await LexicalEntryDraftFactory.makeInput(entry: entry, pack: pack)

    #expect(input.language == "en-Latn")
    #expect(input.senses[0].definitionLanguage == nil)
    #expect(Set(input.pronunciations.map(\.id)).count == input.pronunciations.count)
    let audio = try #require(input.pronunciations.first { if case .audio = $0.content { true } else { false } })
    #expect(audio.isSelected == false)
    #expect(audio.availabilityError?.contains("OGG") == true)
}

@Test func previewRejectsCardAmplificationAndOversizedFieldsBeforeMaterializing() {
    let tooMany = VocabularyDeckInput(
        deckName: "Bounded",
        form: "word",
        senses: [
            .init(id: "1", definition: "one"),
            .init(id: "2", definition: "two"),
            .init(id: "3", definition: "three"),
        ],
        paradigms: [.formToMeaning]
    )
    #expect(throws: VocabularyDeckBuilderError.tooManyCards(actual: 3, maximum: 2)) {
        try VocabularyDeckGenerator.preview(
            input: tooMany,
            builderLimits: .init(maximumCards: 2)
        )
    }

    let oversized = VocabularyDeckInput(
        deckName: "Deck",
        form: "12345",
        pronunciations: [.init(id: "p", scheme: "ipa", displayLabel: "IPA", content: .text("x"))],
        paradigms: [.formToPronunciation]
    )
    #expect(throws: VocabularyDeckBuilderError.fieldTooLarge("Canonical form", maximumBytes: 4)) {
        try VocabularyDeckGenerator.preview(
            input: oversized,
            builderLimits: .init(maximumTextFieldBytes: 4)
        )
    }
}

@Test func previewRejectsOversizedSourceMetadataAndNonregularAudio() throws {
    let metadata = VocabularyDeckInput(
        deckName: "Metadata",
        form: "word",
        senses: [.init(id: "sense", definition: "definition")],
        paradigms: [.formToMeaning],
        sourceContext: .init(
            packID: "pack",
            entryID: "entry",
            pack: .init(sourceID: "source", attribution: String(repeating: "a", count: 20))
        )
    )
    #expect(throws: VocabularyDeckBuilderError.sourceMetadataTooLarge(maximumBytes: 10)) {
        try VocabularyDeckGenerator.preview(
            input: metadata,
            builderLimits: .init(maximumSourceMetadataBytes: 10)
        )
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-audio-\(UUID().uuidString).wav", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = VocabularyDeckInput(
        deckName: "Audio",
        form: "word",
        pronunciations: [
            .init(id: "directory", scheme: "recording", displayLabel: "Recording", content: .audio(root)),
        ],
        paradigms: [.formToPronunciation]
    )
    #expect(throws: VocabularyDeckBuilderError.invalidAudio(
        "Pronunciation directory must be a non-symbolic-link regular file."
    )) {
        try VocabularyDeckGenerator.preview(input: audio)
    }
}

private func characterOffset(of needle: String, in text: String) -> Int? {
    guard let range = text.range(of: needle) else { return nil }
    return text[..<range.lowerBound].count
}

private struct TestWorkspaceProvider: DeckBuildWorkspaceProviding {
    func makeWorkspace() throws -> GeneratedDeckBundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-builder-tests-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Generated.neoanki", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return GeneratedDeckBundle(bundleURL: bundle) {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
