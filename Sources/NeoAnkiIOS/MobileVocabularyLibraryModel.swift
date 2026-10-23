#if os(iOS)
import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiVocabularyKit
import Observation
import VocabularyDeckBuilder

@MainActor
@Observable
final class MobileVocabularyLibraryModel {
    let sync: VocabularyPackSyncModel
    private(set) var installedPacks: [InstalledVocabularyPack] = []
    private(set) var isLoading = false
    private(set) var isImporting = false
    var errorMessage: String?

    init(rootURL: URL, cloudTransport: (any VocabularyPackCloudTransport)? = nil) {
        sync = VocabularyPackSyncModel(rootURL: rootURL, transport: cloudTransport)
    }

    var builderOptions: [VocabularyPackOption] {
        installedPacks.map { pack in
            let languages = pack.languages.joined(separator: ", ")
            let noun = pack.entryCount == 1 ? "entry" : "entries"
            return VocabularyPackOption(
                id: pack.id,
                title: pack.title,
                summary: "\(languages) · \(pack.entryCount.formatted()) \(noun)",
                packageURL: pack.packageURL
            )
        }
    }

    func seedVisualFixtureIfRequested(library: (any LibraryRepository)? = nil) async throws {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-NeoAnkiUITestingReset"),
              ["mobile-vocabulary", "mobile-item-lookup"].contains(process.environment["NEOANKI_TEST_SCENARIO"] ?? "") else { return }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vocabulary-visual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let entries = workspace.appendingPathComponent("entries.jsonl")
        var entry = LexicalEntry(id: "en:swift", language: "en", canonicalForm: .init(text: .init("swift", language: "en")),
            senses: [.init(id: "quick", definitions: [.init(text: .init("Moving quickly and smoothly.", language: "en"))])])
        var fixtureEntries: [LexicalEntry] = []
        if process.environment["NEOANKI_TEST_SCENARIO"] == "mobile-item-lookup", let library {
            entry.pronunciations = [.init(scheme: "ipa", representations: [.text(.init("ˈswɪft"))])]
            let photo = FieldDef(name: "Photo", type: .image, isRequired: false)
            let name = FieldDef(name: "Name", type: .text, isRequired: true)
            _ = try await library.createItemType(ItemType(name: "Photo Names", fields: [photo, name], templates: [
                Template(name: "Name it", prompt: Side(slots: [Slot(source: .field(photo.id))]),
                         answer: Side(slots: [Slot(source: .field(name.id))]), interaction: .reveal,
                         skill: Skill(input: .image, output: .text, operation: .recognize))
            ]))
            _ = try await library.createDeck(Deck(name: "Words"))
            let word = FieldDef(name: "Слово без наголосу", type: .text, isRequired: true)
            let stress = FieldDef(name: "Форма з наголосом", type: .text, isRequired: true)
            let phrase = FieldDef(name: "Фраза", type: .text, isRequired: true)
            _ = try await library.createItemType(ItemType(name: "Наголос", fields: [word, stress, phrase], templates: [
                Template(name: "Поставити наголос", prompt: Side(slots: [Slot(source: .field(word.id))]),
                         answer: Side(slots: [Slot(source: .field(stress.id))]), interaction: .reveal,
                         skill: Skill(input: .text, output: .text, operation: .recall))
            ]))
            _ = try await library.createDeck(Deck(name: "Наголоси"))
            fixtureEntries.append(LexicalEntry(id: "uk:nachynka", language: "uk", canonicalForm: .init(text: .init("начинка")),
                pronunciations: [.init(scheme: "orthographic-respelling", representations: [.text(.init("НА\u{301}ЧИНКА"))])],
                senses: [.init(id: "filling", definitions: [.init(text: .init("Те, чим начиняють що-небудь, готуючи їстівне."))])]))
        }
        fixtureEntries.insert(entry, at: 0)
        try fixtureEntries.reduce(into: Data()) { data, entry in
            data += try JSONEncoder().encode(entry) + Data([0x0A])
        }.write(to: entries)
        let package = workspace.appendingPathComponent("Acceptance.neovocab", isDirectory: true)
        _ = try VocabularyPackCompiler.compile(jsonlURL: entries, to: package,
            descriptor: .init(id: "visual.en", title: "Acceptance Lexicon", languages: ["en"], capabilities: [.lexicon]))
        _ = try await sync.installLocal(from: package)
#if DEBUG && targetEnvironment(simulator)
        // Optional real-pack regression coverage stays inside the disposable
        // Simulator fixture path and never applies to a physical installation.
        if let path = process.environment["NEOANKI_TEST_LARGE_DICTIONARY"] {
            _ = try await sync.installLocal(from: URL(fileURLWithPath: path))
        }
#endif
        installedPacks = sync.localPacks
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await sync.reloadLocal()
        installedPacks = sync.localPacks
    }

    func install(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
            isImporting = false
        }
        do {
            _ = try await sync.installLocal(from: url)
            installedPacks = sync.localPacks
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
#endif
