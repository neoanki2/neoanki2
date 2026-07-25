import Foundation
import NeoAnkiCore

enum ImportFileFormat: String, Sendable {
    case json = "JSON"
    case csv = "CSV"
}

@MainActor
@Observable
final class ImportModel {
    private(set) var selectedURL: URL?
    private(set) var format: ImportFileFormat?
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private(set) var importedCount: Int?
    var selectedItemTypeID: ItemType.ID?

    private let itemsModel: ItemsModel

    init(itemsModel: ItemsModel) {
        self.itemsModel = itemsModel
    }

    var selectedFileName: String {
        selectedURL?.lastPathComponent ?? ""
    }

    var needsItemTypeSelection: Bool {
        format == .csv
    }

    var canImport: Bool {
        guard selectedURL != nil, !isImporting else { return false }
        return !needsItemTypeSelection || selectedItemTypeID != nil
    }

    @discardableResult
    func selectFile(_ url: URL) -> Bool {
        errorMessage = nil
        importedCount = nil

        switch url.pathExtension.lowercased() {
        case "json":
            format = .json
        case "csv":
            format = .csv
        default:
            selectedURL = nil
            format = nil
            errorMessage = "Choose a JSON or CSV file."
            return false
        }

        selectedURL = url
        if format == .csv,
           !itemsModel.itemTypes.contains(where: { $0.id == selectedItemTypeID }) {
            selectedItemTypeID = itemsModel.itemTypes.first?.id
        }
        return true
    }

    func cancel() {
        guard !isImporting else { return }
        selectedURL = nil
        format = nil
        errorMessage = nil
        importedCount = nil
    }

    @discardableResult
    func importSelected(scope: StudyScope) async -> Bool {
        guard let selectedURL, let format else {
            errorMessage = "Choose a JSON or CSV file."
            return false
        }

        isImporting = true
        errorMessage = nil
        importedCount = nil
        defer { isImporting = false }

        let hasSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let fileSize = try selectedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let fileSize, fileSize > ImportLimits.maxPayloadBytes {
                throw ImportError.invalidFormat(
                    "The file is larger than \(ImportLimits.maxPayloadBytes / 1_000_000) MB."
                )
            }

            let data = try Data(contentsOf: selectedURL, options: .mappedIfSafe)
            let count: Int
            switch format {
            case .json:
                count = try await itemsModel.store.importItems(
                    from: data,
                    adapter: JSONImportAdapter(),
                    context: ImportContext(baseDirectory: selectedURL.deletingLastPathComponent())
                )
            case .csv:
                guard let itemType = itemsModel.itemTypes.first(where: { $0.id == selectedItemTypeID }) else {
                    errorMessage = "Choose an item type for this CSV file."
                    return false
                }
                count = try await itemsModel.store.importItems(
                    from: data,
                    adapter: CSVImportAdapter(itemTypeName: itemType.name),
                    itemTypeID: itemType.id,
                    context: ImportContext(baseDirectory: selectedURL.deletingLastPathComponent())
                )
            }

            importedCount = count
            await itemsModel.load(scope: scope)
            return true
        } catch {
            errorMessage = UserFacingError.importMessage(from: error)
            return false
        }
    }
}
