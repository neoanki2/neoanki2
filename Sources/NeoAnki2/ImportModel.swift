import Foundation
import NeoAnkiApplication
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

struct ImportFileInspection: Sendable {
    let containsRelativeMediaPaths: Bool
}

protocol ImportFileInspecting: Sendable {
    func inspectSelection(at url: URL, format: ImportFileFormat) async throws -> ImportFileInspection
    func readPayload(at url: URL) async throws -> Data
}

struct SystemImportFileInspector: ImportFileInspecting {
    private let relativeMediaProbe: @Sendable (Data) -> Bool

    init(
        relativeMediaProbe: @escaping @Sendable (Data) -> Bool = SystemImportFileInspector.containsRelativePath
    ) {
        self.relativeMediaProbe = relativeMediaProbe
    }

    func inspectSelection(at url: URL, format: ImportFileFormat) async throws -> ImportFileInspection {
        let relativeMediaProbe = self.relativeMediaProbe
        return try await Task.detached(priority: .userInitiated) {
            try Self.validateFileSize(at: url)
            guard format == .json else {
                return ImportFileInspection(containsRelativeMediaPaths: false)
            }
            let data = try Self.readBoundedPayload(at: url)
            return ImportFileInspection(containsRelativeMediaPaths: relativeMediaProbe(data))
        }.value
    }

    func readPayload(at url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Self.validateFileSize(at: url)
            return try Self.readBoundedPayload(at: url)
        }.value
    }

    private static func validateFileSize(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ImportError.invalidFormat("Choose a regular JSON or CSV file.")
        }
        if let size = values.fileSize, size > ImportLimits.maxPayloadBytes {
            throw oversizedFileError
        }
    }

    private static func readBoundedPayload(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximumProbeBytes = ImportLimits.maxPayloadBytes + 1
        let data = try handle.read(upToCount: maximumProbeBytes) ?? Data()
        guard data.count <= ImportLimits.maxPayloadBytes else {
            throw oversizedFileError
        }
        return data
    }

    private static var oversizedFileError: ImportError {
        .invalidFormat("The file is larger than \(ImportLimits.maxPayloadBytes / 1_000_000) MB.")
    }

    private static func containsRelativePath(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return containsRelativePath(in: object)
    }

    private static func containsRelativePath(in value: Any) -> Bool {
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
    private let library: any LibraryImporting
    private let scopedAccess: any SecurityScopedResourceAccessing
    private let fileInspector: any ImportFileInspecting

    init(
        itemsModel: ItemsModel,
        library: any LibraryImporting,
        scopedAccess: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccess(),
        fileInspector: any ImportFileInspecting = SystemImportFileInspector()
    ) {
        self.itemsModel = itemsModel
        self.library = library
        self.scopedAccess = scopedAccess
        self.fileInspector = fileInspector
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
    func selectFile(_ url: URL) async -> Bool {
        errorMessage = nil
        importedCount = nil

        let selectedFormat: ImportFileFormat
        switch url.pathExtension.lowercased() {
        case "json":
            selectedFormat = .json
        case "csv":
            selectedFormat = .csv
        default:
            selectedURL = nil
            format = nil
            errorMessage = "Choose a JSON or CSV file."
            return false
        }

        let didStart = scopedAccess.startAccessing(url)
        defer {
            if didStart {
                scopedAccess.stopAccessing(url)
            }
        }

        do {
            let inspection = try await fileInspector.inspectSelection(at: url, format: selectedFormat)
            format = selectedFormat
            selectedURL = url
            mediaDirectoryURL = nil
            requiresMediaDirectory = inspection.containsRelativeMediaPaths
            if selectedFormat == .csv,
               !itemsModel.itemTypes.contains(where: { $0.id == selectedItemTypeID }) {
                selectedItemTypeID = itemsModel.itemTypes.first?.id
            }
            return true
        } catch {
            selectedURL = nil
            mediaDirectoryURL = nil
            requiresMediaDirectory = false
            format = nil
            errorMessage = UserFacingError.importMessage(from: error)
            return false
        }
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
            let data = try await fileInspector.readPayload(at: selectedURL)
            let imported: [SavedItemSummary]
            switch format {
            case .json:
                imported = try await library.importJSONItems(
                    from: data,
                    itemTypeID: nil,
                    context: ImportContext(baseDirectory: mediaDirectory ?? selectedURL.deletingLastPathComponent()),
                    asOf: .now
                )
            case .csv:
                guard let itemType = itemsModel.itemTypes.first(where: { $0.id == selectedItemTypeID }) else {
                    errorMessage = "Choose an item type for this CSV file."
                    return false
                }
                imported = try await library.importCSVItems(
                    from: data,
                    itemTypeID: itemType.id,
                    itemTypeName: itemType.name,
                    context: ImportContext(baseDirectory: selectedURL.deletingLastPathComponent()),
                    asOf: .now
                )
            }

            importedCount = imported.count
            await itemsModel.applyImportedItems(imported, scope: scope)
            return true
        } catch {
            errorMessage = UserFacingError.importMessage(from: error)
            return false
        }
    }
}
