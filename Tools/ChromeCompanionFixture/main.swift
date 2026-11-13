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
            && request.requestedScopes == [.libraryRead, .itemsWrite, .vocabularyRead]
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
        let vocabularyRoot = root.appendingPathComponent("vocabulary", isDirectory: true)
        let entries = [
            entry("serendipity", "Finding something good by chance.", pronunciation: "ˌserənˈdɪpəti"),
            entry("serendipitous", "Happening by a fortunate chance."),
            entry("bank", "A financial institution.", id: "bank:finance"),
            entry("bank", "Land beside a river.", id: "bank:river"),
            entry("їжак 🦔", "A hedgehog."),
        ]
        let jsonl = root.appendingPathComponent("entries.jsonl")
        var bytes = Data()
        for value in entries {
            bytes.append(try JSONEncoder().encode(value))
            bytes.append(0x0a)
        }
        try bytes.write(to: jsonl)
        let pack = root.appendingPathComponent("fixture.neovocab", isDirectory: true)
        try VocabularyPackCompiler.compile(
            jsonlURL: jsonl,
            to: pack,
            descriptor: .init(
                id: "companion-fixture", title: "Companion Test Dictionary",
                languages: ["en", "uk"], capabilities: [.lexicon, .pronunciation]
            )
        )
        try await InstalledVocabularyPackStore(rootURL: vocabularyRoot).install(from: pack)
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

    private static func entry(_ word: String, _ meaning: String, id: String? = nil, pronunciation: String? = nil) -> LexicalEntry {
        LexicalEntry(
            id: id ?? word, language: word.hasPrefix("ї") ? "uk" : "en",
            canonicalForm: LexicalForm(text: LocalizedText(word)),
            pronunciations: pronunciation.map { [Pronunciation(scheme: "ipa", representations: [.text(LocalizedText($0))])] } ?? [],
            senses: [LexicalSense(id: "sense-1", definitions: [Definition(text: LocalizedText(meaning))])]
        )
    }

    private enum FixtureError: Error {
        case usage
        case requiresEmptyTemporaryDirectory
    }
}
