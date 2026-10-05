#if os(iOS)
import Foundation
import NeoAnkiVocabularyKit
import Observation
import VocabularyDeckBuilder

@MainActor
@Observable
final class MobileVocabularyLibraryModel {
    private let store: InstalledVocabularyPackStore
    private(set) var installedPacks: [InstalledVocabularyPack] = []
    private(set) var isLoading = false
    private(set) var isImporting = false
    var errorMessage: String?

    init(rootURL: URL) {
        store = InstalledVocabularyPackStore(rootURL: rootURL)
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

    func seedVisualFixtureIfRequested() async throws {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-NeoAnkiUITestingReset"),
              process.environment["NEOANKI_TEST_SCENARIO"] == "mobile-vocabulary" else { return }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vocabulary-visual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let entries = workspace.appendingPathComponent("entries.jsonl")
        let entry = LexicalEntry(id: "en:swift", language: "en", canonicalForm: .init(text: .init("swift", language: "en")),
            senses: [.init(id: "quick", definitions: [.init(text: .init("Moving quickly and smoothly.", language: "en"))])])
        try (JSONEncoder().encode(entry) + Data([0x0A])).write(to: entries)
        let package = workspace.appendingPathComponent("Acceptance.neovocab", isDirectory: true)
        _ = try VocabularyPackCompiler.compile(jsonlURL: entries, to: package,
            descriptor: .init(id: "visual.en", title: "Acceptance Lexicon", languages: ["en"], capabilities: [.lexicon]))
        _ = try await store.install(from: package)
        installedPacks = try await store.installedPacks()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do { installedPacks = try await store.installedPacks() }
        catch { errorMessage = error.localizedDescription }
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
            _ = try await store.install(from: url)
            installedPacks = try await store.installedPacks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(id: String) async {
        do {
            try await store.remove(id: id)
            installedPacks = try await store.installedPacks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
