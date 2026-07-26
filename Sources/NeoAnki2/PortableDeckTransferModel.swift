import Foundation
import NeoAnkiCore
import UniformTypeIdentifiers

extension UTType {
    static let neoDeck = UTType(
        filenameExtension: PortableDeck.fileExtension,
        conformingTo: .database
    )!
    static let neoAnkiSource = UTType(
        filenameExtension: AuthoredDeck.fileExtension,
        conformingTo: .package
    )!
}

struct PortableDeckTransferNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message
    }
}

@MainActor
@Observable
final class PortableDeckTransferModel {
    typealias ImportOperation = @MainActor (
        URL,
        PortableDeckTypeConflictResolution
    ) async throws -> PortableDeckImportResult
    typealias AuthoredImportOperation = @MainActor (
        URL
    ) async throws -> PortableDeckImportResult
    typealias ExportOperation = @MainActor (UUID, URL) async throws -> Void

    private(set) var isBusy = false
    private(set) var conflictingSource: URL?
    var notice: PortableDeckTransferNotice?

    private let importOperation: ImportOperation
    private let authoredImportOperation: AuthoredImportOperation
    private let exportOperation: ExportOperation
    private let scopedAccess: any SecurityScopedResourceAccessing

    init(
        store: ItemStore,
        scopedAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess()
    ) {
        importOperation = { source, resolution in
            try await PortableDeck.importDeck(
                from: source,
                into: store,
                conflictResolution: resolution
            )
        }
        authoredImportOperation = { source in
            try await AuthoredDeck.importDeck(from: source, into: store)
        }
        exportOperation = { deckID, destination in
            try await PortableDeck.export(deckID: deckID, from: store, to: destination)
        }
        self.scopedAccess = scopedAccess
    }

    init(
        scopedAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess(),
        importOperation: @escaping ImportOperation,
        authoredImportOperation: @escaping AuthoredImportOperation = { _ in
            throw AuthoredDeckError.invalid([
                .init(
                    file: AuthoredDeck.manifestName,
                    line: 1,
                    code: "AD900",
                    message: "Authored import is unavailable in this test."
                ),
            ])
        },
        exportOperation: @escaping ExportOperation
    ) {
        self.scopedAccess = scopedAccess
        self.importOperation = importOperation
        self.authoredImportOperation = authoredImportOperation
        self.exportOperation = exportOperation
    }

    func importDeck(
        from source: URL,
        conflictResolution: PortableDeckTypeConflictResolution = .reject
    ) async -> PortableDeckImportResult? {
        guard !isBusy else { return nil }
        isBusy = true
        notice = nil
        if conflictResolution == .reject {
            conflictingSource = nil
        }
        defer { isBusy = false }

        let hasSecurityScope = scopedAccess.startAccessing(source)
        defer {
            if hasSecurityScope {
                scopedAccess.stopAccessing(source)
            }
        }

        do {
            let result: PortableDeckImportResult
            if source.pathExtension.lowercased() == AuthoredDeck.fileExtension {
                result = try await authoredImportOperation(source)
            } else {
                result = try await importOperation(source, conflictResolution)
            }
            conflictingSource = nil
            let noun = result.itemCount == 1 ? "item" : "items"
            notice = PortableDeckTransferNotice(
                title: "Deck Imported",
                message: "\(result.itemCount) \(noun) imported."
            )
            return result
        } catch PortableDeckError.typeConflict {
            conflictingSource = source
            return nil
        } catch {
            notice = PortableDeckTransferNotice(
                title: "Could Not Import Deck",
                message: error.localizedDescription
            )
            return nil
        }
    }

    func resolveConflict(
        using resolution: PortableDeckTypeConflictResolution
    ) async -> PortableDeckImportResult? {
        guard resolution != .reject, let source = conflictingSource else { return nil }
        return await importDeck(from: source, conflictResolution: resolution)
    }

    func cancelConflict() {
        guard !isBusy else { return }
        conflictingSource = nil
    }

    var testingForceBusy: Bool {
        AppDatabase.isTesting
            && ProcessInfo.processInfo.environment["NEOANKI_TEST_PORTABLE_BUSY"] == "1"
    }

    @discardableResult
    func exportDeck(id: UUID, to destination: URL) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        notice = nil
        defer { isBusy = false }

        let hasSecurityScope = scopedAccess.startAccessing(destination)
        defer {
            if hasSecurityScope {
                scopedAccess.stopAccessing(destination)
            }
        }

        do {
            try await exportOperation(id, destination)
            notice = PortableDeckTransferNotice(
                title: "Deck Exported",
                message: "The portable deck was saved successfully."
            )
            return true
        } catch {
            notice = PortableDeckTransferNotice(
                title: "Could Not Export Deck",
                message: error.localizedDescription
            )
            return false
        }
    }
}
