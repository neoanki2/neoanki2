import Foundation
import NeoAnkiVocabularyKit
import Testing

@Test func compilesAndSearchesRichEntriesOffline() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let targetLocation = "Ми ".unicodeScalars.count
    let entry = LexicalEntry(
        id: "uk:застосувати:1",
        language: "uk",
        canonicalForm: LexicalForm(text: LocalizedText("застосувати", language: "uk"), kind: "lemma"),
        forms: [
            LexicalForm(
                text: LocalizedText("застосували", language: "uk"),
                kind: "inflected",
                grammaticalFeatures: [LexicalTrait(name: "tense", value: "past")]
            ),
        ],
        pronunciations: [
            Pronunciation(
                scheme: "orthographic-respelling",
                label: "Stress",
                representations: [.text(LocalizedText("застосува́ти", language: "uk"))]
            ),
            Pronunciation(
                scheme: "ipa",
                representations: [.text(LocalizedText("zɐstosʊˈwɑtɪ"))]
            ),
        ],
        senses: [
            LexicalSense(
                id: "sense-1",
                definitions: [Definition(text: LocalizedText("Використати щось.", language: "uk"))],
                examples: [
                    UsageExample(
                        text: LocalizedText("Ми застосували метод.", language: "uk"),
                        target: ExampleTarget(
                            exactText: "застосували",
                            scalarRange: UnicodeScalarRange(location: targetLocation, length: "застосували".unicodeScalars.count)
                        )
                    ),
                ]
            ),
            LexicalSense(
                id: "sense-2",
                definitions: [Definition(text: LocalizedText("Ужити на практиці.", language: "uk"))]
            ),
        ],
        provenance: Provenance(sourceID: "fixture", sourceName: "Offline fixture")
    )
    let second = LexicalEntry(
        id: "uk:застава:1",
        language: "uk",
        canonicalForm: LexicalForm(text: LocalizedText("застава", language: "uk"))
    )
    let jsonl = try workspace.writeJSONL([entry, second])
    let packURL = workspace.root.appendingPathComponent("Ukrainian.neovocab", isDirectory: true)
    let manifest = try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: VocabularyPackDescriptor(
            id: "fixture.uk",
            title: "Ukrainian Fixture",
            languages: ["uk"],
            capabilities: [.lexicon, .pronunciation, .morphology, .corpus]
        )
    )

    #expect(manifest.entryCount == 2)
    #expect(manifest.capabilities.contains(.corpus))
    let pack = try await VocabularyPack.open(at: packURL)
    #expect(pack.manifest.title == "Ukrainian Fixture")

    let exact = try await pack.search(query: "ЗАСТОСУВАТИ", mode: .exact)
    #expect(exact.map(\.id) == [entry.id])
    #expect(exact[0].pronunciations.count == 2)
    #expect(exact[0].senses.count == 2)

    let byInflectedForm = try await pack.search(query: "застосували", mode: .exact)
    #expect(byInflectedForm.map(\.id) == [entry.id])
    let prefix = try await pack.search(query: "заст", mode: .prefix, language: "uk")
    #expect(Set(prefix.map(\.id)) == Set([entry.id, second.id]))
    #expect(try await pack.entry(id: entry.id) == entry)
}

@Test func compilerCopiesOnlyReferencedLocalAudio() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let media = workspace.root.appendingPathComponent("source-media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let nested = media.appendingPathComponent("speaker", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: nested.appendingPathComponent("word.ogg"))
    try Data([9]).write(to: media.appendingPathComponent("unused.ogg"))
    let entry = LexicalEntry(
        id: "audio:1",
        language: "und",
        canonicalForm: LexicalForm(text: LocalizedText("word")),
        pronunciations: [
            Pronunciation(
                scheme: "recording",
                representations: [.audio(AudioReference(path: "speaker/word.ogg", mimeType: "audio/ogg"))]
            ),
        ]
    )
    let jsonl = try workspace.writeJSONL([entry])
    let packURL = workspace.root.appendingPathComponent("Audio.neovocab")
    let manifest = try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "audio", title: "Audio", languages: ["und"], capabilities: [.pronunciation]),
        options: .init(mediaDirectoryURL: media)
    )
    #expect(manifest.mediaFiles.map(\.path) == ["speaker/word.ogg"])
    let pack = try await VocabularyPack.open(at: packURL)
    let resolved = try await pack.mediaURL(for: AudioReference(path: "speaker/word.ogg"))
    #expect(try Data(contentsOf: resolved) == Data([1, 2, 3]))
    #expect(!FileManager.default.fileExists(atPath: packURL.appendingPathComponent("media/unused.ogg").path))
}

@Test func rejectsMalformedJSONAndInvalidUnicodeTargetRange() throws {
    let malformedWorkspace = try TestWorkspace()
    defer { malformedWorkspace.cleanup() }
    let malformed = malformedWorkspace.root.appendingPathComponent("bad.jsonl")
    try Data("{not-json}\n".utf8).write(to: malformed)
    #expect(throws: VocabularyPackError.self) {
        try VocabularyPackCompiler.compile(
            jsonlURL: malformed,
            to: malformedWorkspace.root.appendingPathComponent("Bad.neovocab"),
            descriptor: .init(id: "bad", title: "Bad", languages: [], capabilities: [])
        )
    }

    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let badRange = LexicalEntry(
        id: "bad-range",
        language: "uk",
        canonicalForm: LexicalForm(text: LocalizedText("їжак", language: "uk")),
        senses: [
            LexicalSense(
                id: "1",
                examples: [
                    UsageExample(
                        text: LocalizedText("🦔 їжак"),
                        target: ExampleTarget(
                            exactText: "їжак",
                            scalarRange: UnicodeScalarRange(location: 0, length: 4)
                        )
                    ),
                ]
            ),
        ]
    )
    let jsonl = try workspace.writeJSONL([badRange])
    #expect(throws: VocabularyPackError.self) {
        try VocabularyPackCompiler.compile(
            jsonlURL: jsonl,
            to: workspace.root.appendingPathComponent("BadRange.neovocab"),
            descriptor: .init(id: "bad-range", title: "Bad range", languages: ["uk"], capabilities: [.corpus])
        )
    }
}

@Test func rejectsTamperedDatabaseAndSymlinkedManifest() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let entry = LexicalEntry(
        id: "one",
        language: "en",
        canonicalForm: LexicalForm(text: LocalizedText("one", language: "en"))
    )
    let jsonl = try workspace.writeJSONL([entry])
    let tampered = workspace.root.appendingPathComponent("Tampered.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: tampered,
        descriptor: .init(id: "one", title: "One", languages: ["en"], capabilities: [.lexicon])
    )
    let database = tampered.appendingPathComponent("lexicon.sqlite")
    let handle = try FileHandle(forWritingTo: database)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0]))
    try handle.close()
    await #expect(throws: VocabularyPackError.self) {
        try await VocabularyPack.open(at: tampered)
    }

    let linked = workspace.root.appendingPathComponent("Linked.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: linked,
        descriptor: .init(id: "linked", title: "Linked", languages: ["en"], capabilities: [.lexicon])
    )
    let manifest = linked.appendingPathComponent("manifest.json")
    let outside = workspace.root.appendingPathComponent("outside.json")
    try FileManager.default.moveItem(at: manifest, to: outside)
    try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
    await #expect(throws: VocabularyPackError.self) {
        try await VocabularyPack.open(at: linked)
    }
}

@Test func publicIORejectsNetworkURLsAndUnsafeMediaPaths() async throws {
    let remote = try #require(URL(string: "https://example.invalid/pack.neovocab"))
    await #expect(throws: VocabularyPackError.self) {
        try await VocabularyPack.open(at: remote)
    }

    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let entry = LexicalEntry(
        id: "unsafe",
        language: "en",
        canonicalForm: LexicalForm(text: LocalizedText("unsafe")),
        pronunciations: [
            Pronunciation(scheme: "audio", representations: [.audio(AudioReference(path: "../escape.ogg"))]),
        ]
    )
    let jsonl = try workspace.writeJSONL([entry])
    #expect(throws: VocabularyPackError.self) {
        try VocabularyPackCompiler.compile(
            jsonlURL: jsonl,
            to: workspace.root.appendingPathComponent("Unsafe.neovocab"),
            descriptor: .init(id: "unsafe", title: "Unsafe", languages: ["en"], capabilities: [.pronunciation])
        )
    }
}

@Test func prefixSearchTreatsWildcardsLiterallyAndPreservesEmbeddedNUL() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let entries = [
        LexicalEntry(
            id: "percent",
            language: "und",
            canonicalForm: LexicalForm(text: LocalizedText("100%word"))
        ),
        LexicalEntry(
            id: "underscore",
            language: "und",
            canonicalForm: LexicalForm(text: LocalizedText("under_score"))
        ),
        LexicalEntry(
            id: "nul\u{0}id",
            language: "und",
            canonicalForm: LexicalForm(text: LocalizedText("ab\u{0}cd"))
        ),
    ]
    let jsonl = try workspace.writeJSONL(entries)
    let packURL = workspace.root.appendingPathComponent("Keys.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "keys", title: "Keys", languages: ["und"], capabilities: [.lexicon])
    )
    let pack = try await VocabularyPack.open(at: packURL)
    #expect(try await pack.search(query: "100%", mode: .prefix).map(\.id) == ["percent"])
    #expect(try await pack.search(query: "under_", mode: .prefix).map(\.id) == ["underscore"])
    #expect(try await pack.search(query: "ab\u{0}", mode: .prefix).map(\.id) == ["nul\u{0}id"])
    #expect(try await pack.entry(id: "nul\u{0}id")?.id == "nul\u{0}id")
}

@Test func searchRejectsResultsBeyondCumulativeByteLimit() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let entry = LexicalEntry(
        id: "large",
        language: "en",
        canonicalForm: LexicalForm(text: LocalizedText("large")),
        senses: [LexicalSense(id: "1", definitions: [Definition(text: LocalizedText(String(repeating: "x", count: 512)))])]
    )
    let jsonl = try workspace.writeJSONL([entry])
    let packURL = workspace.root.appendingPathComponent("Bounded.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "bounded", title: "Bounded", languages: ["en"], capabilities: [.lexicon])
    )
    let pack = try await VocabularyPack.open(
        at: packURL,
        limits: VocabularyPackLimits(maximumSearchResultBytes: 64)
    )
    await #expect(throws: VocabularyPackError.self) {
        try await pack.search(query: "lar", mode: .prefix)
    }
}

@Test func mediaResolutionRevalidatesHashAndRejectsIntermediateSymlinkSwap() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let media = workspace.root.appendingPathComponent("source-media", isDirectory: true)
    let speaker = media.appendingPathComponent("speaker", isDirectory: true)
    try FileManager.default.createDirectory(at: speaker, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: speaker.appendingPathComponent("word.ogg"))
    let entry = LexicalEntry(
        id: "audio",
        language: "und",
        canonicalForm: LexicalForm(text: LocalizedText("word")),
        pronunciations: [
            Pronunciation(
                scheme: "audio",
                representations: [.audio(AudioReference(path: "speaker/word.ogg"))]
            ),
        ]
    )
    let jsonl = try workspace.writeJSONL([entry])
    let packURL = workspace.root.appendingPathComponent("AudioSwap.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "audio", title: "Audio", languages: ["und"], capabilities: [.pronunciation]),
        options: .init(mediaDirectoryURL: media)
    )
    let pack = try await VocabularyPack.open(at: packURL)
    let reference = AudioReference(path: "speaker/word.ogg")
    let packagedFile = try await pack.mediaURL(for: reference)
    try Data([3, 2, 1]).write(to: packagedFile)
    await #expect(throws: VocabularyPackError.self) {
        try await pack.mediaURL(for: reference)
    }

    let packagedSpeaker = packURL.appendingPathComponent("media/speaker", isDirectory: true)
    let movedSpeaker = workspace.root.appendingPathComponent("moved-speaker", isDirectory: true)
    try FileManager.default.moveItem(at: packagedSpeaker, to: movedSpeaker)
    try FileManager.default.createSymbolicLink(at: packagedSpeaker, withDestinationURL: movedSpeaker)
    await #expect(throws: VocabularyPackError.self) {
        try await pack.mediaURL(for: reference)
    }
}

@Test func hostileMediaSizesFailWithoutIntegerOverflow() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let media = workspace.root.appendingPathComponent("source-media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    try Data([1]).write(to: media.appendingPathComponent("a.ogg"))
    try Data([2]).write(to: media.appendingPathComponent("b.ogg"))
    let entry = LexicalEntry(
        id: "audio",
        language: "und",
        canonicalForm: LexicalForm(text: LocalizedText("word")),
        pronunciations: [
            Pronunciation(
                scheme: "audio",
                representations: [
                    .audio(AudioReference(path: "a.ogg")),
                    .audio(AudioReference(path: "b.ogg")),
                ]
            ),
        ]
    )
    let jsonl = try workspace.writeJSONL([entry])
    let packURL = workspace.root.appendingPathComponent("Overflow.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "overflow", title: "Overflow", languages: ["und"], capabilities: [.pronunciation]),
        options: .init(mediaDirectoryURL: media)
    )
    let manifestURL = packURL.appendingPathComponent("manifest.json")
    var manifest = try JSONDecoder().decode(
        VocabularyPackManifest.self,
        from: Data(contentsOf: manifestURL)
    )
    manifest.mediaFiles[0].byteSize = 1
    manifest.mediaFiles[1].byteSize = .max
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    await #expect(throws: VocabularyPackError.self) {
        try await VocabularyPack.open(at: packURL)
    }
}

@Test func fineGrainedProvenanceCompilesAndRoundTrips() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let formSource = Provenance(sourceID: "forms", sourceName: "Morphology dictionary", recordID: "form-1")
    let pronunciationSource = Provenance(
        sourceID: "pronunciations",
        sourceName: "Pronunciation dictionary",
        attribution: "Dictionary editors"
    )
    let definitionSource = Provenance(
        sourceID: "definitions",
        sourceName: "Explanatory dictionary",
        license: "Personal-use source"
    )
    let entry = LexicalEntry(
        id: "provenance",
        language: "uk",
        canonicalForm: LexicalForm(
            id: "lemma",
            text: LocalizedText("слово", language: "uk"),
            provenance: formSource
        ),
        pronunciations: [
            Pronunciation(
                id: "pronunciation",
                scheme: "orthographic-respelling",
                representations: [.text(LocalizedText("сло́во", language: "uk"))],
                formIDs: ["lemma"],
                provenance: pronunciationSource
            ),
        ],
        senses: [
            LexicalSense(
                id: "sense",
                definitions: [
                    Definition(
                        id: "definition",
                        text: LocalizedText("Одиниця мови.", language: "uk"),
                        provenance: definitionSource
                    ),
                ]
            ),
        ]
    )
    let jsonl = try workspace.writeJSONL([entry])
    let packURL = workspace.root.appendingPathComponent("Provenance.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "provenance", title: "Provenance", languages: ["uk"], capabilities: [.lexicon])
    )
    let pack = try await VocabularyPack.open(at: packURL)
    let decoded = try #require(try await pack.entry(id: entry.id))
    #expect(decoded.canonicalForm.provenance == formSource)
    #expect(decoded.pronunciations[0].provenance == pronunciationSource)
    #expect(decoded.senses[0].definitions[0].provenance == definitionSource)
}

@Test func fineGrainedProvenanceIsBackwardCompatibleAndValidated() throws {
    let legacyPronunciation = Data(
        #"{"scheme":"ipa","representations":[{"text":{"_0":{"value":"wɜːd"}}}]}"#.utf8
    )
    let decoded = try JSONDecoder().decode(Pronunciation.self, from: legacyPronunciation)
    #expect(decoded.formIDs.isEmpty)
    #expect(decoded.senseIDs.isEmpty)
    #expect(decoded.provenance == nil)
    let reencoded = try JSONEncoder().encode(decoded)
    let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
    #expect(object["formIDs"] == nil)
    #expect(object["senseIDs"] == nil)
    #expect(object["provenance"] == nil)

    let invalid = Provenance(sourceID: "   ")
    let invalidEntries = [
        LexicalEntry(
            id: "form",
            language: "und",
            canonicalForm: LexicalForm(text: LocalizedText("form"), provenance: invalid)
        ),
        LexicalEntry(
            id: "pronunciation",
            language: "und",
            canonicalForm: LexicalForm(text: LocalizedText("pronunciation")),
            pronunciations: [
                Pronunciation(
                    scheme: "ipa",
                    representations: [.text(LocalizedText("p"))],
                    provenance: invalid
                ),
            ]
        ),
        LexicalEntry(
            id: "definition",
            language: "und",
            canonicalForm: LexicalForm(text: LocalizedText("definition")),
            senses: [
                LexicalSense(
                    id: "sense",
                    definitions: [Definition(text: LocalizedText("meaning"), provenance: invalid)]
                ),
            ]
        ),
    ]
    for entry in invalidEntries {
        let workspace = try TestWorkspace()
        defer { workspace.cleanup() }
        let jsonl = try workspace.writeJSONL([entry])
        #expect(throws: VocabularyPackError.self) {
            try VocabularyPackCompiler.compile(
                jsonlURL: jsonl,
                to: workspace.root.appendingPathComponent("Invalid.neovocab"),
                descriptor: .init(id: "invalid", title: "Invalid", languages: [], capabilities: [])
            )
        }
    }
}

@Test func pronunciationApplicabilityRoundTripsAndRejectsUnknownReferences() async throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let valid = LexicalEntry(
        id: "heteronym",
        language: "und",
        canonicalForm: LexicalForm(id: "lemma", text: LocalizedText("lead")),
        pronunciations: [
            Pronunciation(
                id: "verb-pronunciation",
                scheme: "ipa",
                representations: [.text(LocalizedText("/li\u{2D0}d/"))],
                formIDs: ["lemma"],
                senseIDs: ["verb"]
            ),
        ],
        senses: [LexicalSense(id: "verb")]
    )
    let jsonl = try workspace.writeJSONL([valid])
    let packURL = workspace.root.appendingPathComponent("Applicable.neovocab")
    try VocabularyPackCompiler.compile(
        jsonlURL: jsonl,
        to: packURL,
        descriptor: .init(id: "applicable", title: "Applicable", languages: ["und"], capabilities: [.pronunciation])
    )
    let pack = try await VocabularyPack.open(at: packURL)
    let loaded = try #require(try await pack.entry(id: valid.id))
    #expect(loaded.pronunciations[0].formIDs == ["lemma"])
    #expect(loaded.pronunciations[0].senseIDs == ["verb"])

    var invalid = valid
    invalid.id = "invalid"
    invalid.pronunciations[0].senseIDs = ["missing"]
    let invalidJSONL = try workspace.writeJSONL([invalid])
    #expect(throws: VocabularyPackError.self) {
        try VocabularyPackCompiler.compile(
            jsonlURL: invalidJSONL,
            to: workspace.root.appendingPathComponent("InvalidApplicable.neovocab"),
            descriptor: .init(id: "invalid", title: "Invalid", languages: ["und"], capabilities: [.pronunciation])
        )
    }
}

@Test func compilerRejectsDuplicateScopedIDsAndAmbiguousUnrangedTargets() throws {
    let workspace = try TestWorkspace()
    defer { workspace.cleanup() }
    let entry = LexicalEntry(
        id: "duplicates",
        language: "en",
        canonicalForm: LexicalForm(text: LocalizedText("had")),
        senses: [
            LexicalSense(
                id: "sense",
                examples: [
                    UsageExample(
                        id: "repeated",
                        text: LocalizedText("Had had a different meaning."),
                        target: ExampleTarget(exactText: "Had")
                    ),
                    UsageExample(
                        id: "repeated",
                        text: LocalizedText("Had another meaning."),
                        target: ExampleTarget(exactText: "Had")
                    ),
                ]
            ),
        ]
    )
    let duplicateJSONL = try workspace.writeJSONL([entry])
    #expect(throws: VocabularyPackError.self) {
        try VocabularyPackCompiler.compile(
            jsonlURL: duplicateJSONL,
            to: workspace.root.appendingPathComponent("DuplicateIDs.neovocab"),
            descriptor: .init(id: "duplicates", title: "Duplicates", languages: ["en"], capabilities: [.corpus])
        )
    }

    var ambiguous = entry
    ambiguous.id = "ambiguous"
    ambiguous.senses[0].examples = [
        UsageExample(
            id: "ambiguous-example",
            text: LocalizedText("had had"),
            target: ExampleTarget(exactText: "had")
        ),
    ]
    let ambiguousJSONL = try workspace.writeJSONL([ambiguous])
    #expect(throws: VocabularyPackError.self) {
        try VocabularyPackCompiler.compile(
            jsonlURL: ambiguousJSONL,
            to: workspace.root.appendingPathComponent("Ambiguous.neovocab"),
            descriptor: .init(id: "ambiguous", title: "Ambiguous", languages: ["en"], capabilities: [.corpus])
        )
    }
}

private struct TestWorkspace {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoanki-vocabulary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeJSONL(_ entries: [LexicalEntry]) throws -> URL {
        let url = root.appendingPathComponent("entries-\(UUID().uuidString).jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }
}
