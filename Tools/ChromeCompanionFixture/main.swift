import Foundation
import Network
import NeoAnkiAPI
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit

// Explicitly opted-in, temporary test data only. Production uses the app's approval UI.
private struct FixtureApprover: APIPairingApprover {
    func approve(_ request: APIPairingRequest) async -> Bool {
        request.displayName == "NeoAnki2 Chrome Companion"
            && request.origin?.hasPrefix("chrome-extension://") == true
            && request.requestedScopes == [.libraryRead, .itemsWrite, .vocabularyRead, .knownWordsRead, .knownWordsWrite]
    }
}

@main
struct ChromeCompanionFixture {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[1] == "--test-fixture",
              let port = UInt16(arguments[2]), port >= 1024 else {
            throw FixtureError.usage
        }
        let root = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("neoanki-chrome-"),
              FileManager.default.fileExists(atPath: root.path),
              try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw FixtureError.requiresEmptyTemporaryDirectory
        }
        let store = try ItemStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        try await store.bootstrap()
        try await store.createDeck(Deck(name: "Browser vocabulary"))
        try await store.createDeck(Deck(name: "Ukrainian vocabulary"))
        let vocabularyRoot = root.appendingPathComponent("vocabulary", isDirectory: true)
        let entries = [
            entry("serendipity", "Finding something good by chance.", pronunciation: "ˌserənˈdɪpəti"),
            entry("serendipitous", "Happening by a fortunate chance."),
            entry("bank", "A financial institution.", id: "bank:finance"),
            entry("bank", "Land beside a river.", id: "bank:river"),
            entry("їжак 🦔", "A hedgehog."),
            entry("поруччя", "A railing.", language: "uk", meaningLanguage: "en", forms: ["поруччям"]),
            entry("кіптявий", "а, е.", language: "uk", meaningLanguage: "uk"),
            entry("млость", "и, ж.", language: "uk", meaningLanguage: "uk"),
            // Inflected, stress-marked Ukrainian with frequencies, for dictionary forms and frequency bands.
            entry("кни́жка", "A small book.", language: "uk", forms: ["кни́жку", "кни́жки"], frequency: 50),
            entry("ха́та", "A house.", language: "uk", forms: ["ха́ту"], frequency: 80),
        ]
        let packs = InstalledVocabularyPackStore(rootURL: vocabularyRoot)
        try await install(entries, descriptor: .init(
            id: "companion-fixture", title: "Companion Test Dictionary",
            languages: ["en", "uk"], capabilities: [.lexicon, .pronunciation, .morphology, .frequency]
        ), root: root, packs: packs)
        try await install([
            entry("поруччя", "Те саме, що по́ручні.", language: "uk", meaningLanguage: "uk", forms: ["поруччям"],
                  example: .init(text: .init("Поруччя блищало на сонці.", language: "uk"), target: .init(exactText: "Поруччя"),
                                 provenance: .init(sourceID: "fixture-sum11", sourceName: "СУМ-11", attribution: "(Тестовий автор, 12)"))),
            entry("череда", "Ряд предметів.", language: "uk", meaningLanguage: "uk", forms: ["чередою"],
                  example: .init(text: .init("Події тяглися чередою.", language: "uk"), target: .init(exactText: "чередою"),
                                 provenance: .init(sourceID: "fixture-sum11", sourceName: "СУМ-11", attribution: "(Тестовий автор, 19)"))),
            entry("поручні", "Невисока огорожа, за яку можна триматися.", language: "uk", meaningLanguage: "uk"),
            entry("кіптявий", "Який коптить.", language: "uk", meaningLanguage: "uk"),
        ], descriptor: .init(
            id: "ukrainian-fixture", title: "Ukrainian Test Dictionary", languages: ["uk"], capabilities: [.lexicon]
        ), root: root, packs: packs)
        let service = NeoAnkiAPIService(
            library: SQLiteLibraryRepository(store: store),
            authorization: APIAuthorizationStore(persistence: InMemoryAPICredentialPersistence()),
            pairingApprover: FixtureApprover(), applicationVersion: "chrome-test-fixture",
            authority: "127.0.0.1:\(port)", vocabularyRootURL: vocabularyRoot
        )
        let server = NeoAnkiLocalAPIServer(service: service, configuration: .init(port: NWEndpoint.Port(rawValue: port)!))
        try await server.start()
        FileHandle.standardOutput.write(Data("CHROME_FIXTURE_READY\n".utf8))
        // The parent owns stdin and closes it in finally, including after failed assertions.
        await Task.detached { while readLine() != nil {} }.value
        await server.stop()
    }

    private static func install(_ entries: [LexicalEntry], descriptor: VocabularyPackDescriptor, root: URL,
                                packs: InstalledVocabularyPackStore) async throws {
        var bytes = Data()
        let encoder = JSONEncoder()
        for value in entries {
            bytes.append(try encoder.encode(value))
            bytes.append(0x0a)
        }
        let jsonl = root.appendingPathComponent("\(descriptor.id).jsonl")
        try bytes.write(to: jsonl)
        let pack = root.appendingPathComponent("\(descriptor.id).neovocab", isDirectory: true)
        try VocabularyPackCompiler.compile(jsonlURL: jsonl, to: pack, descriptor: descriptor)
        try await packs.install(from: pack)
    }

    private static func entry(
        _ word: String, _ meaning: String, id: String? = nil, pronunciation: String? = nil,
        language: String? = nil, meaningLanguage: String? = nil, forms: [String] = [], frequency: Double? = nil,
        example: UsageExample? = nil
    ) -> LexicalEntry {
        LexicalEntry(
            id: id ?? word, language: language ?? (word.hasPrefix("ї") ? "uk" : "en"),
            canonicalForm: LexicalForm(text: LocalizedText(word)),
            forms: forms.map { LexicalForm(text: LocalizedText($0), kind: "inflected") },
            pronunciations: pronunciation.map { [Pronunciation(scheme: "ipa", representations: [.text(LocalizedText($0))])] } ?? [],
            senses: [LexicalSense(id: "sense-1", definitions: [Definition(text: LocalizedText(meaning, language: meaningLanguage))],
                                  examples: example.map { [$0] } ?? [])],
            frequency: frequency
        )
    }

    private enum FixtureError: Error {
        case usage
        case requiresEmptyTemporaryDirectory
    }
}
