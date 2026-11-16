import Foundation
import NeoAnkiVocabularyKit

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
    var installedPacks: [InstalledVocabularyPack] { sync.localPacks }
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

        do {
            let imported = try await sync.installLocal(from: sourceURL)
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
}
