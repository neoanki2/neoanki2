import Foundation
import NeoAnkiVocabularyKit
import VocabularyDeckBuilder

struct VocabularyLibraryNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message
    }
}

private enum VocabularyLibraryError: LocalizedError {
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            "Choose a local directory whose name ends in .neovocab."
        }
    }
}

@MainActor
@Observable
final class VocabularyLibraryModel {
    private(set) var installedPacks: [VocabularyPackOption] = []
    private(set) var isLoading = false
    private(set) var isImporting = false
    var notice: VocabularyLibraryNotice?

    let rootURL: URL
    let sync: VocabularyPackSyncModel

    init(rootURL: URL, cloudTransport: (any VocabularyPackCloudTransport)? = nil) {
        self.rootURL = rootURL
        sync = VocabularyPackSyncModel(rootURL: rootURL, transport: cloudTransport)
    }

    func load() async {
        guard !isLoading, !isImporting else { return }
        isLoading = true
        defer { isLoading = false }
        await sync.reloadLocal()
        let rootURL = rootURL
        do {
            installedPacks = try await Task.detached(priority: .utility) {
                try Self.scan(rootURL: rootURL)
            }.value
        } catch {
            notice = .init(
                title: "Could Not Load Vocabulary Packs",
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    func importPack(from sourceURL: URL) async -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        notice = nil
        defer { isImporting = false }

        guard sourceURL.isFileURL,
              sourceURL.pathExtension.lowercased() == "neovocab" else {
            notice = .init(
                title: "Could Not Import Vocabulary Pack",
                message: VocabularyLibraryError.invalidSelection.localizedDescription
            )
            return false
        }

        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let rootURL = rootURL
        do {
            let imported = try await sync.installLocal(from: sourceURL)
            installedPacks = try await Task.detached(priority: .utility) {
                try Self.scan(rootURL: rootURL)
            }.value
            notice = .init(
                title: "Vocabulary Pack Imported",
                message: "\(imported.title) is available for offline vocabulary lookup."
            )
            return true
        } catch {
            notice = .init(
                title: "Could Not Import Vocabulary Pack",
                message: error.localizedDescription
            )
            return false
        }
    }

    private nonisolated static func scan(rootURL: URL) throws -> [VocabularyPackOption] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension.lowercased() == "neovocab" }
            .map { option(manifest: try readManifest(at: $0), packageURL: $0) }
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private nonisolated static func readManifest(at packageURL: URL) throws
        -> VocabularyPackManifest
    {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= VocabularyPackLimits.default.maximumManifestBytes else {
            throw VocabularyPackError.invalidPackage("manifest.json is missing or too large.")
        }
        let manifest = try JSONDecoder().decode(
            VocabularyPackManifest.self,
            from: Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        )
        guard manifest.format == "neoanki-vocabulary-pack",
              manifest.formatVersion == VocabularyPackManifest.currentFormatVersion else {
            throw VocabularyPackError.invalidPackage("manifest format is not supported.")
        }
        return manifest
    }

    private nonisolated static func option(
        manifest: VocabularyPackManifest,
        packageURL: URL
    ) -> VocabularyPackOption {
        let languages = manifest.languages.joined(separator: ", ")
        let noun = manifest.entryCount == 1 ? "entry" : "entries"
        return VocabularyPackOption(
            id: manifest.id,
            title: manifest.title,
            summary: "\(languages) · \(manifest.entryCount.formatted()) \(noun)",
            packageURL: packageURL
        )
    }
}
