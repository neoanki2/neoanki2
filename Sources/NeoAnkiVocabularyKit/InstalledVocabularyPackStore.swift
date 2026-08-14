import Foundation

public struct InstalledVocabularyPack: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let languages: [String]
    public let entryCount: Int
    public let packageURL: URL

    public init(
        id: String,
        title: String,
        languages: [String],
        entryCount: Int,
        packageURL: URL
    ) {
        self.id = id
        self.title = title
        self.languages = languages
        self.entryCount = entryCount
        self.packageURL = packageURL
    }
}

public enum InstalledVocabularyPackStoreError: LocalizedError, Equatable {
    case invalidSelection
    case alreadyInstalled(String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .invalidSelection:
            "Choose a local package whose name ends in .neovocab."
        case let .alreadyInstalled(title):
            "\(title) is already installed."
        case .notInstalled:
            "That vocabulary pack is no longer installed."
        }
    }
}

/// Device-local, offline storage for validated `.neovocab` packages.
///
/// Packages are copied through a staging directory and opened by `VocabularyPack`
/// before becoming visible. This keeps partial or corrupt imports out of the
/// installed collection and intentionally has no synchronization dependency.
public actor InstalledVocabularyPackStore {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func installedPacks() throws -> [InstalledVocabularyPack] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "neovocab" }
        .map { try installedPack(at: $0) }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    public func install(from sourceURL: URL) async throws -> InstalledVocabularyPack {
        guard sourceURL.isFileURL,
              sourceURL.pathExtension.lowercased() == "neovocab" else {
            throw InstalledVocabularyPackStoreError.invalidSelection
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let openedSource = try await VocabularyPack.open(at: sourceURL)
        let current = try installedPacks()
        if current.contains(where: { $0.id == openedSource.manifest.id }) {
            throw InstalledVocabularyPackStoreError.alreadyInstalled(openedSource.manifest.title)
        }

        let stagingURL = rootURL.appendingPathComponent(
            ".import-\(UUID().uuidString).neovocab",
            isDirectory: true
        )
        let destinationURL = rootURL.appendingPathComponent(
            "\(UUID().uuidString).neovocab",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        let stagedPack = try await VocabularyPack.open(at: stagingURL)
        if current.contains(where: { $0.id == stagedPack.manifest.id }) {
            throw InstalledVocabularyPackStoreError.alreadyInstalled(stagedPack.manifest.title)
        }
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
        return installedPack(manifest: stagedPack.manifest, packageURL: destinationURL)
    }

    public func remove(id: String) throws {
        guard let pack = try installedPacks().first(where: { $0.id == id }) else {
            throw InstalledVocabularyPackStoreError.notInstalled
        }
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let package = pack.packageURL.resolvingSymlinksInPath().standardizedFileURL
        guard package.deletingLastPathComponent() == root else {
            throw InstalledVocabularyPackStoreError.notInstalled
        }
        try fileManager.removeItem(at: package)
    }

    private func installedPack(at packageURL: URL) throws -> InstalledVocabularyPack {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VocabularyPackError.invalidPackage("Installed package is not a regular directory.")
        }
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true,
              let size = manifestValues.fileSize,
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
        return installedPack(manifest: manifest, packageURL: packageURL)
    }

    private func installedPack(
        manifest: VocabularyPackManifest,
        packageURL: URL
    ) -> InstalledVocabularyPack {
        InstalledVocabularyPack(
            id: manifest.id,
            title: manifest.title,
            languages: manifest.languages,
            entryCount: manifest.entryCount,
            packageURL: packageURL
        )
    }
}
