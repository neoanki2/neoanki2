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
