import Foundation
import NeoAnkiCore

@MainActor
protocol SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

@MainActor
struct SystemSecurityScopedResourceAccess: SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum ImportFileFormat: String, Sendable {
    case json = "JSON"
    case csv = "CSV"
}

@MainActor
@Observable
final class ImportModel {
    private(set) var selectedURL: URL?
    private(set) var mediaDirectoryURL: URL?
    private(set) var requiresMediaDirectory = false
    private(set) var format: ImportFileFormat?
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private(set) var importedCount: Int?
    var selectedItemTypeID: ItemType.ID?

    private let itemsModel: ItemsModel
    private let scopedAccess: any SecurityScopedResourceAccessing

    init(
        itemsModel: ItemsModel,
        scopedAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess()
    ) {
        self.itemsModel = itemsModel
        self.scopedAccess = scopedAccess
    }

    var selectedFileName: String {
        selectedURL?.lastPathComponent ?? ""
    }

    var selectedMediaDirectoryName: String {
        mediaDirectoryURL?.lastPathComponent ?? ""
    }

    var needsItemTypeSelection: Bool {
        format == .csv
    }

    var canImport: Bool {
        guard selectedURL != nil, !isImporting, !requiresMediaDirectory || mediaDirectoryURL != nil else {
            return false
        }
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
        mediaDirectoryURL = nil
        requiresMediaDirectory = format == .json && jsonContainsRelativeMediaPaths(at: url)
        if format == .csv,
           !itemsModel.itemTypes.contains(where: { $0.id == selectedItemTypeID }) {
            selectedItemTypeID = itemsModel.itemTypes.first?.id
        }
        return true
    }

    @discardableResult
    func selectMediaDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            errorMessage = "Choose the folder containing this import’s media files."
            return false
        }
        mediaDirectoryURL = url
        errorMessage = nil
        return true
    }

    func cancel() {
        guard !isImporting else { return }
        selectedURL = nil
        mediaDirectoryURL = nil
        requiresMediaDirectory = false
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

        let hasSecurityScope = scopedAccess.startAccessing(selectedURL)
        let mediaDirectory = mediaDirectoryURL
        let hasDirectoryScope = mediaDirectory.map(scopedAccess.startAccessing) ?? false
        defer {
            if hasDirectoryScope, let mediaDirectory {
                scopedAccess.stopAccessing(mediaDirectory)
            }
            if hasSecurityScope {
                scopedAccess.stopAccessing(selectedURL)
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
                    context: ImportContext(baseDirectory: mediaDirectory ?? selectedURL.deletingLastPathComponent())
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

    private func jsonContainsRelativeMediaPaths(at url: URL) -> Bool {
        let didStart = scopedAccess.startAccessing(url)
        defer {
            if didStart {
                scopedAccess.stopAccessing(url)
            }
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= ImportLimits.maxPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }
        return containsRelativePath(in: object)
    }

    private func containsRelativePath(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let path = dictionary["path"] as? String,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !NSString(string: path).isAbsolutePath {
                return true
            }
            return dictionary.values.contains(where: containsRelativePath)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsRelativePath)
        }
        return false
    }
}
