import CryptoKit
import Foundation
import SQLite3

public struct VocabularyPackDescriptor: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var summary: String?
    public var languages: [String]
    public var capabilities: Set<VocabularyCapability>
    public var provenance: Provenance?

    public init(
        id: String,
        title: String,
        summary: String? = nil,
        languages: [String],
        capabilities: Set<VocabularyCapability>,
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.languages = languages
        self.capabilities = capabilities
        self.provenance = provenance
    }
}

public struct VocabularyPackManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var id: String
    public var title: String
    public var summary: String?
    public var languages: [String]
    public var capabilities: Set<VocabularyCapability>
    public var provenance: Provenance?
    public var entryCount: Int
    public var databaseFile: String
    public var databaseSHA256: String
    public var mediaFiles: [VocabularyPackMediaFile]

    public init(
        format: String = "neoanki-vocabulary-pack",
        formatVersion: Int = Self.currentFormatVersion,
        id: String,
        title: String,
        summary: String? = nil,
        languages: [String],
        capabilities: Set<VocabularyCapability>,
        provenance: Provenance? = nil,
        entryCount: Int,
        databaseFile: String = "lexicon.sqlite",
        databaseSHA256: String,
        mediaFiles: [VocabularyPackMediaFile] = []
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.id = id
        self.title = title
        self.summary = summary
        self.languages = languages
        self.capabilities = capabilities
        self.provenance = provenance
        self.entryCount = entryCount
        self.databaseFile = databaseFile
        self.databaseSHA256 = databaseSHA256
        self.mediaFiles = mediaFiles
    }
}

public struct VocabularyPackMediaFile: Codable, Hashable, Sendable {
    public var path: String
    public var byteSize: Int64
    public var sha256: String

    public init(path: String, byteSize: Int64, sha256: String) {
        self.path = path
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

public struct VocabularyPackLimits: Sendable, Equatable {
    public var maximumPackBytes: Int64
    public var maximumManifestBytes: Int
    public var maximumEntries: Int
    public var maximumJSONLineBytes: Int
    public var maximumEncodedEntryBytes: Int
    public var maximumFormsPerEntry: Int
    public var maximumSensesPerEntry: Int
    public var maximumExamplesPerSense: Int
    public var maximumDefinitionsPerSense: Int
    public var maximumPronunciationsPerEntry: Int
    public var maximumRepresentationsPerPronunciation: Int
    public var maximumTraitsPerForm: Int
    public var maximumLabelsPerSense: Int
    public var maximumIndexedTextBytes: Int
    public var maximumAudioPathBytes: Int
    public var maximumMediaBytes: Int64
    public var maximumMediaFiles: Int
    public var maximumMediaTreeEntries: Int
    public var maximumMediaPathDepth: Int
    public var maximumSearchQueryBytes: Int
    public var maximumSearchResultBytes: Int

    public init(
        maximumPackBytes: Int64 = 4_000_000_000,
        maximumManifestBytes: Int = 1_000_000,
        maximumEntries: Int = 5_000_000,
        maximumJSONLineBytes: Int = 8_000_000,
        maximumEncodedEntryBytes: Int = 8_000_000,
        maximumFormsPerEntry: Int = 10_000,
        maximumSensesPerEntry: Int = 1_000,
        maximumExamplesPerSense: Int = 10_000,
        maximumDefinitionsPerSense: Int = 1_000,
        maximumPronunciationsPerEntry: Int = 1_000,
        maximumRepresentationsPerPronunciation: Int = 1_000,
        maximumTraitsPerForm: Int = 256,
        maximumLabelsPerSense: Int = 1_000,
        maximumIndexedTextBytes: Int = 1_048_576,
        maximumAudioPathBytes: Int = 4_096,
        maximumMediaBytes: Int64 = 2_000_000_000,
        maximumMediaFiles: Int = 100_000,
        maximumMediaTreeEntries: Int = 200_000,
        maximumMediaPathDepth: Int = 64,
        maximumSearchQueryBytes: Int = 65_536,
        maximumSearchResultBytes: Int = 32_000_000
    ) {
        self.maximumPackBytes = maximumPackBytes
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumEntries = maximumEntries
        self.maximumJSONLineBytes = maximumJSONLineBytes
        self.maximumEncodedEntryBytes = maximumEncodedEntryBytes
        self.maximumFormsPerEntry = maximumFormsPerEntry
        self.maximumSensesPerEntry = maximumSensesPerEntry
        self.maximumExamplesPerSense = maximumExamplesPerSense
        self.maximumDefinitionsPerSense = maximumDefinitionsPerSense
        self.maximumPronunciationsPerEntry = maximumPronunciationsPerEntry
        self.maximumRepresentationsPerPronunciation = maximumRepresentationsPerPronunciation
        self.maximumTraitsPerForm = maximumTraitsPerForm
        self.maximumLabelsPerSense = maximumLabelsPerSense
        self.maximumIndexedTextBytes = maximumIndexedTextBytes
        self.maximumAudioPathBytes = maximumAudioPathBytes
        self.maximumMediaBytes = maximumMediaBytes
        self.maximumMediaFiles = maximumMediaFiles
        self.maximumMediaTreeEntries = maximumMediaTreeEntries
        self.maximumMediaPathDepth = maximumMediaPathDepth
        self.maximumSearchQueryBytes = maximumSearchQueryBytes
        self.maximumSearchResultBytes = maximumSearchResultBytes
    }

    public static let `default` = VocabularyPackLimits()
}

public enum VocabularySearchMode: String, Codable, Sendable {
    case exact
    case prefix
}

public enum VocabularyPackError: Error, Sendable, Equatable, LocalizedError {
    case nonLocalURL
    case invalidPackage(String)
    case unsupportedVersion(Int)
    case limitExceeded(String)
    case malformedEntry(line: Int, reason: String)
    case duplicateEntryID(String)
    case databaseFailure(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .nonLocalURL: "Vocabulary packs and sources must be local files."
        case let .invalidPackage(reason): "Invalid vocabulary pack: \(reason)"
        case let .unsupportedVersion(version): "Vocabulary pack version \(version) is not supported."
        case let .limitExceeded(reason): "Vocabulary pack limit exceeded: \(reason)"
        case let .malformedEntry(line, reason): "Malformed JSONL entry on line \(line): \(reason)"
        case let .duplicateEntryID(id): "Duplicate lexical entry ID: \(id)"
        case let .databaseFailure(reason): "Vocabulary database error: \(reason)"
        case let .ioFailure(reason): "Vocabulary pack I/O error: \(reason)"
        }
    }
}

/// A read-only actor over an installed local `.neovocab` directory.
///
/// This module deliberately has no networking API. Both opening and media resolution reject
/// non-file URLs, and SQLite is opened read-only after path, schema, and digest validation.
public actor VocabularyPack {
    public nonisolated let manifest: VocabularyPackManifest
    public nonisolated let packageURL: URL

    private let database: VocabularySQLiteDatabase
    private let limits: VocabularyPackLimits

    private init(
        packageURL: URL,
        manifest: VocabularyPackManifest,
        database: VocabularySQLiteDatabase,
        limits: VocabularyPackLimits
    ) {
        self.packageURL = packageURL
        self.manifest = manifest
        self.database = database
        self.limits = limits
    }

    public static func open(
        at packageURL: URL,
        limits: VocabularyPackLimits = .default
    ) async throws -> VocabularyPack {
        guard packageURL.isFileURL else { throw VocabularyPackError.nonLocalURL }
        let root = packageURL.standardizedFileURL
        guard root.pathExtension.lowercased() == "neovocab" else {
            throw VocabularyPackError.invalidPackage("Expected a .neovocab directory.")
        }
        try FileSafety.requireDirectory(root, label: "package")

        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        try FileSafety.requireRegularFile(manifestURL, label: "manifest")
        let manifestSize = try FileSafety.fileSize(manifestURL)
        guard manifestSize <= Int64(limits.maximumManifestBytes) else {
            throw VocabularyPackError.limitExceeded("manifest.json is too large")
        }
        let manifestData: Data
        do { manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe]) }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }

        let manifest: VocabularyPackManifest
        do { manifest = try JSONDecoder().decode(VocabularyPackManifest.self, from: manifestData) }
        catch { throw VocabularyPackError.invalidPackage("manifest.json is malformed: \(error.localizedDescription)") }
        guard manifest.format == "neoanki-vocabulary-pack" else {
            throw VocabularyPackError.invalidPackage("Unknown manifest format.")
        }
        guard manifest.formatVersion == VocabularyPackManifest.currentFormatVersion else {
            throw VocabularyPackError.unsupportedVersion(manifest.formatVersion)
        }
        guard FileSafety.isSafeSingleFilename(manifest.databaseFile) else {
            throw VocabularyPackError.invalidPackage("Unsafe database filename.")
        }
        guard manifest.entryCount >= 0, manifest.entryCount <= limits.maximumEntries else {
            throw VocabularyPackError.limitExceeded("entry count")
        }

        try FileSafety.validatePackageRoot(root, databaseFilename: manifest.databaseFile)
        let databaseURL = root.appendingPathComponent(manifest.databaseFile, isDirectory: false)
        try FileSafety.requireRegularFile(databaseURL, label: "database")
        let databaseSize = try FileSafety.fileSize(databaseURL)
        guard databaseSize <= limits.maximumPackBytes else {
            throw VocabularyPackError.limitExceeded("database file is too large")
        }
        guard FileSafety.isSHA256Hex(manifest.databaseSHA256) else {
            throw VocabularyPackError.invalidPackage("Database checksum is not a SHA-256 digest.")
        }
        let digest = try SHA256File.hexDigest(of: databaseURL)
        guard digest == manifest.databaseSHA256.lowercased() else {
            throw VocabularyPackError.invalidPackage("Database checksum does not match manifest.")
        }
        let mediaSize = try validateMedia(in: root, manifest: manifest, limits: limits)
        let (dataSize, dataOverflow) = databaseSize.addingReportingOverflow(mediaSize)
        let (packageSize, manifestOverflow) = dataSize.addingReportingOverflow(manifestSize)
        guard !dataOverflow, !manifestOverflow, packageSize <= limits.maximumPackBytes else {
            throw VocabularyPackError.limitExceeded("package exceeds total byte limit")
        }

        let database = try VocabularySQLiteDatabase(url: databaseURL, readOnly: true)
        try database.validateForReading(expectedEntries: manifest.entryCount)
        return VocabularyPack(packageURL: root, manifest: manifest, database: database, limits: limits)
    }

    private static func validateMedia(
        in root: URL,
        manifest: VocabularyPackManifest,
        limits: VocabularyPackLimits
    ) throws -> Int64 {
        guard manifest.mediaFiles.count <= limits.maximumMediaFiles else {
            throw VocabularyPackError.limitExceeded("too many media files")
        }
        let mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        if manifest.mediaFiles.isEmpty {
            if FileManager.default.fileExists(atPath: mediaRoot.path(percentEncoded: false)) {
                try FileSafety.requireDirectory(mediaRoot, label: "media")
                guard try FileSafety.regularFilesRecursively(in: mediaRoot, limits: limits).isEmpty else {
                    throw VocabularyPackError.invalidPackage("Media directory contains unlisted files.")
                }
            }
            return 0
        }
        try FileSafety.requireDirectory(mediaRoot, label: "media")
        var declaredPaths = Set<String>()
        var totalBytes: Int64 = 0
        for media in manifest.mediaFiles {
            guard FileSafety.isSafeRelativePath(media.path), declaredPaths.insert(media.path).inserted else {
                throw VocabularyPackError.invalidPackage("Unsafe or duplicate media manifest path.")
            }
            guard media.byteSize >= 0 else {
                throw VocabularyPackError.invalidPackage("Negative media size.")
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(media.byteSize)
            guard !overflow, newTotal <= limits.maximumMediaBytes else {
                throw VocabularyPackError.limitExceeded("media exceeds byte limit")
            }
            totalBytes = newTotal
            guard FileSafety.isSHA256Hex(media.sha256) else {
                throw VocabularyPackError.invalidPackage("Media checksum is not a SHA-256 digest.")
            }
            try FileSafety.requireNoSymlinkComponents(relativePath: media.path, below: mediaRoot)
            let file = mediaRoot.appendingPathComponent(media.path).standardizedFileURL
            try FileSafety.requireRegularFile(file, label: "media")
            guard try FileSafety.fileSize(file) == media.byteSize else {
                throw VocabularyPackError.invalidPackage("Media size does not match manifest.")
            }
            guard try SHA256File.hexDigest(of: file) == media.sha256.lowercased() else {
                throw VocabularyPackError.invalidPackage("Media checksum does not match manifest.")
            }
        }
        let packagedPaths = Set(try FileSafety.regularFilesRecursively(in: mediaRoot, limits: limits))
        guard packagedPaths == declaredPaths else {
            throw VocabularyPackError.invalidPackage("Media directory does not match manifest.")
        }
        return totalBytes
    }

    public func search(
        query: String,
        mode: VocabularySearchMode = .prefix,
        limit: Int = 50,
        language: String? = nil
    ) throws -> [LexicalEntry] {
        let boundedLimit = min(max(limit, 1), 500)
        guard query.utf8.count <= limits.maximumSearchQueryBytes,
              language?.utf8.count ?? 0 <= limits.maximumSearchQueryBytes
        else {
            throw VocabularyPackError.limitExceeded("search query is too large")
        }
        let key = VocabularySearchKey.make(query)
        guard !key.isEmpty else { return [] }
        guard key.utf8.count <= limits.maximumSearchQueryBytes else {
            throw VocabularyPackError.limitExceeded("search query is too large")
        }
        return try database.search(
            key: key,
            mode: mode,
            limit: boundedLimit,
            language: language,
            maximumResultBytes: limits.maximumSearchResultBytes,
            maximumEntryBytes: limits.maximumEncodedEntryBytes
        )
    }

    public func entry(id: String) throws -> LexicalEntry? {
        guard id.utf8.count <= limits.maximumSearchQueryBytes else {
            throw VocabularyPackError.limitExceeded("entry ID is too large")
        }
        return try database.entry(id: id, maximumEntryBytes: limits.maximumEncodedEntryBytes)
    }

    public func mediaURL(for reference: AudioReference) throws -> URL {
        guard FileSafety.isSafeRelativePath(reference.path) else {
            throw VocabularyPackError.invalidPackage("Unsafe media path.")
        }
        let mediaRoot = packageURL.appendingPathComponent("media", isDirectory: true)
        guard let descriptor = manifest.mediaFiles.first(where: { $0.path == reference.path }) else {
            throw VocabularyPackError.invalidPackage("Audio reference is not declared in the manifest.")
        }
        try FileSafety.requireDirectory(mediaRoot, label: "media")
        try FileSafety.requireNoSymlinkComponents(relativePath: reference.path, below: mediaRoot)
        let candidate = mediaRoot.appendingPathComponent(reference.path, isDirectory: false).standardizedFileURL
        let resolvedRoot = mediaRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw VocabularyPackError.invalidPackage("Media path escapes package.")
        }
        try FileSafety.requireRegularFile(candidate, label: "media")
        guard try FileSafety.fileSize(candidate) == descriptor.byteSize,
              try SHA256File.hexDigest(of: candidate) == descriptor.sha256.lowercased()
        else {
            throw VocabularyPackError.invalidPackage("Media changed after the pack was opened.")
        }
        return candidate
    }
}

enum VocabularySearchKey {
    static func make(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FileSafety {
    static func validatePackageRoot(_ root: URL, databaseFilename: String) throws {
        let allowed = Set(["manifest.json", databaseFilename, "media"])
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
        } catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        for child in children {
            guard allowed.contains(child.lastPathComponent) else {
                throw VocabularyPackError.invalidPackage("Package contains an unexpected top-level item.")
            }
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw VocabularyPackError.invalidPackage("Package contains a symbolic link.")
            }
        }
    }

    static func requireDirectory(_ url: URL, label: String) throws {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        guard values.isSymbolicLink != true else {
            throw VocabularyPackError.invalidPackage("\(label) must not be a symbolic link.")
        }
        guard values.isDirectory == true else {
            throw VocabularyPackError.invalidPackage("\(label) is not a directory.")
        }
    }

    static func requireRegularFile(_ url: URL, label: String) throws {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        guard values.isSymbolicLink != true else {
            throw VocabularyPackError.invalidPackage("\(label) must not be a symbolic link.")
        }
        guard values.isRegularFile == true else {
            throw VocabularyPackError.invalidPackage("\(label) is not a regular file.")
        }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else {
                throw VocabularyPackError.invalidPackage("Cannot determine file size.")
            }
            return Int64(size)
        } catch let error as VocabularyPackError { throw error }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
    }

    static func isSafeSingleFilename(_ path: String) -> Bool {
        !path.isEmpty && path != "." && path != ".." && !path.contains("/") && !path.contains("\\")
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
        }
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func requireNoSymlinkComponents(relativePath: String, below root: URL) throws {
        guard isSafeRelativePath(relativePath) else {
            throw VocabularyPackError.invalidPackage("Unsafe relative path.")
        }
        var cursor = root.standardizedFileURL
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            let values: URLResourceValues
            do { values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]) }
            catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
            guard values.isSymbolicLink != true else {
                throw VocabularyPackError.invalidPackage("Media path contains a symbolic link.")
            }
        }
    }

    static func regularFilesRecursively(
        in root: URL,
        limits: VocabularyPackLimits
    ) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { throw VocabularyPackError.ioFailure("Cannot enumerate media directory.") }
        let rootPath = root.standardizedFileURL.path
        var result: [String] = []
        var visited = 0
        for case let candidate as URL in enumerator {
            visited += 1
            guard visited <= limits.maximumMediaTreeEntries else {
                throw VocabularyPackError.limitExceeded("media tree contains too many entries")
            }
            let values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw VocabularyPackError.invalidPackage("Media directory contains a symbolic link.")
            }
            let path = candidate.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else {
                throw VocabularyPackError.invalidPackage("Media path escapes package.")
            }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            guard relativePath.split(separator: "/").count <= limits.maximumMediaPathDepth else {
                throw VocabularyPackError.limitExceeded("media path is too deep")
            }
            if values.isRegularFile == true {
                result.append(relativePath)
            } else if values.isDirectory != true {
                throw VocabularyPackError.invalidPackage("Media tree contains a non-file entry.")
            }
        }
        return result
    }
}

enum SHA256File {
    static func hexDigest(of url: URL) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch { throw VocabularyPackError.ioFailure(error.localizedDescription) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
