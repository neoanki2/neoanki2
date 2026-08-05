import Darwin
import CryptoKit
import Foundation
import NeoAnkiVocabularyKit

struct APIVocabularyProvenance: Codable, Sendable, Equatable {
    let sourceId: String
    let sourceName: String?
    let recordId: String?
    let attribution: String?
    let license: String?
    let sourceUrl: String?

    init(_ value: Provenance) {
        sourceId = value.sourceID
        sourceName = value.sourceName
        recordId = value.recordID
        attribution = value.attribution
        license = value.license
        sourceUrl = value.sourceURL
    }
}

struct APIVocabularyPack: Codable, Sendable, Equatable {
    let id: String
    let revision: Int
    let title: String
    let summary: String?
    let languages: [String]
    let capabilities: [String]
    let provenance: APIVocabularyProvenance?
    let entryCount: Int
    let databaseSha256: String
    let mediaFileCount: Int
    let mediaByteCount: Int64

    init(_ manifest: VocabularyPackManifest) throws {
        let mediaByteCount = try manifest.mediaFiles.reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.byteSize)
            guard !overflow else {
                throw APIServiceError.validation("Vocabulary media size overflows its limit.")
            }
            return sum
        }
        id = manifest.id
        revision = 1
        title = manifest.title
        summary = manifest.summary
        languages = manifest.languages.sorted()
        capabilities = manifest.capabilities.map(\.rawValue).sorted()
        provenance = manifest.provenance.map(APIVocabularyProvenance.init)
        entryCount = manifest.entryCount
        databaseSha256 = manifest.databaseSHA256
        mediaFileCount = manifest.mediaFiles.count
        self.mediaByteCount = mediaByteCount
    }
}

struct APIVocabularyPackCollection: Codable, Sendable {
    let data: [APIVocabularyPack]
}

struct APIVocabularyEntryCollection: Codable, Sendable {
    let data: [LexicalEntry]
}

struct VocabularyImportFileInput: Decodable {
    let id: String
    let path: String
    let byteSize: Int64
    let sha256: String
}

struct CreateVocabularyImportInput: Decodable {
    let files: [VocabularyImportFileInput]
}

struct APIVocabularyImportFile: Codable, Sendable, Equatable {
    let id: String
    let path: String
    let byteSize: Int64
    let sha256: String
    var uploaded: Bool
}

struct APIVocabularyImportJob: Codable, Sendable, Equatable {
    let id: String
    var revision: Int
    var state: String
    var files: [APIVocabularyImportFile]
    var pack: APIVocabularyPack?
    let createdAt: Date
    var updatedAt: Date
}

struct VocabularyMediaPayload: Sendable {
    let bytes: Data?
    let byteCount: Int64
    let sha256: String
    let fileExtension: String
}

actor APIVocabularyLibrary {
    typealias PackOpener = @Sendable (URL) async throws -> VocabularyPack

    static let maximumInstalledPacks = 1_000
    static let maximumDeclaredFiles = 100_002
    static let maximumFileBytes: Int64 = 1_000_000_000
    static let maximumTotalBytes: Int64 = 4_000_000_000
    static let maximumIdentifierBytes = 65_536

    private struct InstalledPack {
        let packageURL: URL
        let pack: VocabularyPack
        let representation: APIVocabularyPack
        let fingerprint: PackTreeFingerprint
    }

    private struct PackTreeFingerprint: Equatable, Sendable {
        let entryCount: Int
        let metadataDigest: Data
    }

    private let rootURL: URL
    private let stagingRootURL: URL
    private let jobLifetime: TimeInterval
    private let openPack: PackOpener
    private var jobs: [UUID: APIVocabularyImportJob] = [:]
    private var jobsLoaded = false
    private var installedPackCache: [URL: InstalledPack] = [:]

    init(
        rootURL: URL,
        jobLifetime: TimeInterval = 24 * 60 * 60,
        openPack: @escaping PackOpener = { try await VocabularyPack.open(at: $0) }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        stagingRootURL = rootURL.standardizedFileURL
            .appendingPathComponent(".api-imports", isDirectory: true)
        self.jobLifetime = jobLifetime
        self.openPack = openPack
    }

    func listPacks() async throws -> [APIVocabularyPack] {
        try await installedPacks().map(\.representation)
    }

    func pack(id: String) async throws -> (VocabularyPack, APIVocabularyPack) {
        let normalizedID = try validateIdentifier(id, pointer: "/id")
        guard let installed = try await installedPacks().first(where: {
            $0.representation.id == normalizedID
        }) else {
            throw APIServiceError.notFound("The requested vocabulary pack does not exist.")
        }
        return (installed.pack, installed.representation)
    }

    func deletePack(id: String) async throws {
        let normalizedID = try validateIdentifier(id, pointer: "/id")
        guard let installed = try await installedPacks().first(where: {
            $0.representation.id == normalizedID
        }) else {
            throw APIServiceError.notFound("The requested vocabulary pack does not exist.")
        }
        try FileManager.default.removeItem(at: installed.packageURL)
        installedPackCache.removeValue(forKey: installed.packageURL)
    }

    func search(
        packID: String,
        query: String,
        mode: VocabularySearchMode,
        limit: Int,
        language: String?
    ) async throws -> [LexicalEntry] {
        let (pack, _) = try await pack(id: packID)
        do {
            return try await pack.search(query: query, mode: mode, limit: limit, language: language)
        } catch {
            throw vocabularyValidationError(error)
        }
    }

    func entry(packID: String, entryID: String) async throws -> LexicalEntry {
        let validatedEntryID = try validateIdentifier(entryID, pointer: "/entryId")
        let (pack, _) = try await pack(id: packID)
        do {
            guard let entry = try await pack.entry(id: validatedEntryID) else {
                throw APIServiceError.notFound("The requested vocabulary entry does not exist.")
            }
            return entry
        } catch let error as APIServiceError {
            throw error
        } catch {
            throw vocabularyValidationError(error)
        }
    }

    func media(packID: String, path: String, includeBytes: Bool) async throws
        -> VocabularyMediaPayload
    {
        let validatedPath = try validateQueryValue(path, pointer: "/query/path")
        let (pack, _) = try await pack(id: packID)
        guard let descriptor = pack.manifest.mediaFiles.first(where: { $0.path == validatedPath }) else {
            throw APIServiceError.notFound("The requested vocabulary media does not exist.")
        }
        do {
            let url = try await pack.mediaURL(for: AudioReference(path: validatedPath))
            return VocabularyMediaPayload(
                bytes: includeBytes ? try Data(contentsOf: url, options: [.mappedIfSafe]) : nil,
                byteCount: descriptor.byteSize,
                sha256: descriptor.sha256,
                fileExtension: url.pathExtension.lowercased()
            )
        } catch {
            throw vocabularyValidationError(error)
        }
    }

    func createImport(_ input: CreateVocabularyImportInput) async throws -> APIVocabularyImportJob {
        let declarations = try validateDeclarations(input.files)
        try ensurePrivateDirectory(rootURL)
        try ensurePrivateDirectory(stagingRootURL)
        try loadJobsIfNeeded()
        try purgeExpiredJobs()

        let id = UUID()
        let now = Date.now
        let job = APIVocabularyImportJob(
            id: id.uuidString.lowercased(),
            revision: 1,
            state: "awaitingFiles",
            files: declarations,
            pack: nil,
            createdAt: now,
            updatedAt: now
        )
        let directory = jobDirectory(id)
        try ensurePrivateDirectory(directory)
        try ensurePrivateDirectory(packageDirectory(id))
        jobs[id] = job
        try persist(job, id: id)
        return job
    }

    func importJob(id: UUID) throws -> APIVocabularyImportJob {
        try loadJobsIfNeeded()
        try purgeExpiredJobs()
        guard let job = jobs[id] else {
            throw APIServiceError.notFound("The requested vocabulary import does not exist.")
        }
        return job
    }

    func upload(jobID: UUID, fileID: UUID, bytes: Data) throws -> APIVocabularyImportJob {
        try loadJobsIfNeeded()
        try purgeExpiredJobs()
        guard var job = jobs[jobID] else {
            throw APIServiceError.notFound("The requested vocabulary import does not exist.")
        }
        guard job.state != "completed" else {
            throw resourceConflict("A completed vocabulary import cannot accept files.")
        }
        guard let index = job.files.firstIndex(where: { $0.id == fileID.uuidString.lowercased() }) else {
            throw APIServiceError.notFound("The declared vocabulary import file does not exist.")
        }
        let declaration = job.files[index]
        guard Int64(bytes.count) == declaration.byteSize else {
            throw APIServiceError.validation(
                "Uploaded bytes do not match the declared size.", pointer: "/body",
                fieldCode: "size_mismatch"
            )
        }
        guard APICrypto.sha256Hex(bytes) == declaration.sha256 else {
            throw APIServiceError.validation(
                "Uploaded bytes do not match the declared SHA-256.", pointer: "/body",
                fieldCode: "digest_mismatch"
            )
        }

        let destination = packageDirectory(jobID)
            .appendingPathComponent(declaration.path, isDirectory: false)
        try ensurePrivateDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".upload-\(UUID().uuidString)", isDirectory: false)
        try bytes.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)

        job.files[index].uploaded = true
        job.state = job.files.allSatisfy(\.uploaded) ? "ready" : "awaitingFiles"
        job.pack = nil
        job.revision += 1
        job.updatedAt = .now
        jobs[jobID] = job
        try persist(job, id: jobID)
        return job
    }

    func validateImport(id: UUID) async throws -> APIVocabularyImportJob {
        try loadJobsIfNeeded()
        try purgeExpiredJobs()
        guard var job = jobs[id] else {
            throw APIServiceError.notFound("The requested vocabulary import does not exist.")
        }
        guard job.state != "completed" else { return job }
        guard job.files.allSatisfy(\.uploaded) else {
            throw APIServiceError.validation("Every declared vocabulary file must be uploaded before validation.")
        }
        let opened: VocabularyPack
        do {
            opened = try await VocabularyPack.open(at: packageDirectory(id))
        } catch {
            throw vocabularyValidationError(error)
        }
        job.pack = try APIVocabularyPack(opened.manifest)
        job.state = "validated"
        job.revision += 1
        job.updatedAt = .now
        jobs[id] = job
        try persist(job, id: id)
        return job
    }

    func commitImport(id: UUID) async throws -> APIVocabularyImportJob {
        try loadJobsIfNeeded()
        try purgeExpiredJobs()
        guard var job = jobs[id] else {
            throw APIServiceError.notFound("The requested vocabulary import does not exist.")
        }
        if job.state == "completed" { return job }
        guard job.state == "validated", let pack = job.pack else {
            throw APIServiceError.validation("The vocabulary import must be validated before commit.")
        }
        guard try await installedPacks().allSatisfy({ $0.representation.id != pack.id }) else {
            throw resourceConflict("A vocabulary pack with this manifest ID is already installed.")
        }
        try ensurePrivateDirectory(rootURL)
        let destination = rootURL.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).neovocab", isDirectory: true
        )
        try FileManager.default.moveItem(at: packageDirectory(id), to: destination)
        job.state = "completed"
        job.revision += 1
        job.updatedAt = .now
        jobs[id] = job
        try persist(job, id: id)
        return job
    }

    func deleteImport(id: UUID) throws {
        try loadJobsIfNeeded()
        try purgeExpiredJobs()
        guard jobs.removeValue(forKey: id) != nil else {
            throw APIServiceError.notFound("The requested vocabulary import does not exist.")
        }
        try FileManager.default.removeItem(at: jobDirectory(id))
    }

    private func installedPacks() async throws -> [InstalledPack] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            installedPackCache.removeAll()
            return []
        }
        let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw installedLibraryInvalid()
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "neovocab" }
        guard urls.count <= Self.maximumInstalledPacks else { throw installedLibraryInvalid() }

        let installedURLs = Set(urls.map(\.standardizedFileURL))
        installedPackCache = installedPackCache.filter { installedURLs.contains($0.key) }

        var result: [InstalledPack] = []
        var ids = Set<String>()
        for candidate in urls {
            let url = candidate.standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw installedLibraryInvalid()
            }
            do {
                let installed = try await validatedInstalledPack(at: url)
                guard ids.insert(installed.pack.manifest.id).inserted else {
                    throw installedLibraryInvalid()
                }
                result.append(installed)
            } catch let error as APIServiceError {
                throw error
            } catch {
                installedPackCache.removeValue(forKey: url)
                throw installedLibraryInvalid()
            }
        }
        return result.sorted {
            let lhs = $0.representation.title.precomposedStringWithCanonicalMapping
            let rhs = $1.representation.title.precomposedStringWithCanonicalMapping
            return lhs == rhs
                ? $0.representation.id < $1.representation.id
                : lhs < rhs
        }
    }

    private func validatedInstalledPack(at url: URL) async throws -> InstalledPack {
        let currentFingerprint = try packTreeFingerprint(at: url)
        if let cached = installedPackCache[url], cached.fingerprint == currentFingerprint {
            return cached
        }

        installedPackCache.removeValue(forKey: url)
        let opened = try await openPack(url)
        let verifiedFingerprint = try packTreeFingerprint(at: url)
        guard currentFingerprint == verifiedFingerprint else {
            throw installedLibraryInvalid()
        }
        let installed = InstalledPack(
            packageURL: url,
            pack: opened,
            representation: try APIVocabularyPack(opened.manifest),
            fingerprint: verifiedFingerprint
        )
        installedPackCache[url] = installed
        return installed
    }

    private func packTreeFingerprint(at root: URL) throws -> PackTreeFingerprint {
        let maximumEntries = VocabularyPackLimits.default.maximumMediaTreeEntries + 3
        var entryCount = 0
        var hasher = SHA256()

        func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        }

        func append(_ url: URL, relativePath: String) throws {
            guard entryCount < maximumEntries else {
                throw installedLibraryInvalid()
            }
            var value = Darwin.stat()
            guard lstat(url.path, &value) == 0 else { throw installedLibraryInvalid() }
            entryCount += 1

            let pathBytes = Data(relativePath.utf8)
            var record = Data(capacity: pathBytes.count + 80)
            appendInteger(UInt64(pathBytes.count), to: &record)
            record.append(pathBytes)
            appendInteger(UInt64(value.st_dev), to: &record)
            appendInteger(UInt64(value.st_ino), to: &record)
            appendInteger(UInt16(value.st_mode), to: &record)
            appendInteger(Int64(value.st_size), to: &record)
            appendInteger(Int64(value.st_mtimespec.tv_sec), to: &record)
            appendInteger(Int64(value.st_mtimespec.tv_nsec), to: &record)
            appendInteger(Int64(value.st_ctimespec.tv_sec), to: &record)
            appendInteger(Int64(value.st_ctimespec.tv_nsec), to: &record)
            hasher.update(data: record)

            guard value.st_mode & S_IFMT == S_IFDIR else { return }
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childPath = relativePath == "."
                    ? child.lastPathComponent
                    : "\(relativePath)/\(child.lastPathComponent)"
                try append(child, relativePath: childPath)
            }
        }

        do {
            try append(root, relativePath: ".")
            return PackTreeFingerprint(
                entryCount: entryCount,
                metadataDigest: Data(hasher.finalize())
            )
        } catch let error as APIServiceError {
            throw error
        } catch {
            throw installedLibraryInvalid()
        }
    }

    private func validateDeclarations(_ values: [VocabularyImportFileInput]) throws
        -> [APIVocabularyImportFile]
    {
        guard (2 ... Self.maximumDeclaredFiles).contains(values.count) else {
            throw APIServiceError.validation(
                "A vocabulary import must declare between 2 and \(Self.maximumDeclaredFiles) files.",
                pointer: "/files"
            )
        }
        var ids = Set<UUID>()
        var paths = Set<String>()
        var total: Int64 = 0
        var topLevelDataFiles = 0
        var declarations: [APIVocabularyImportFile] = []
        for (index, value) in values.enumerated() {
            guard let id = UUID(uuidString: value.id),
                  id.uuidString.lowercased() == value.id else {
                throw APIServiceError.validation(
                    "Expected a lowercase UUID.", pointer: "/files/\(index)/id"
                )
            }
            guard ids.insert(id).inserted else {
                throw APIServiceError.validation(
                    "File IDs must be unique.", pointer: "/files/\(index)/id",
                    fieldCode: "duplicate"
                )
            }
            let path = try validateDeclaredPath(value.path, pointer: "/files/\(index)/path")
            guard paths.insert(path).inserted else {
                throw APIServiceError.validation(
                    "File paths must be unique.", pointer: "/files/\(index)/path",
                    fieldCode: "duplicate"
                )
            }
            guard value.byteSize >= 0, value.byteSize <= Self.maximumFileBytes else {
                throw APIServiceError.validation(
                    "Declared file size is outside the supported range.",
                    pointer: "/files/\(index)/byteSize"
                )
            }
            let (newTotal, overflow) = total.addingReportingOverflow(value.byteSize)
            guard !overflow, newTotal <= Self.maximumTotalBytes else {
                throw APIServiceError.validation(
                    "Declared vocabulary pack size exceeds \(Self.maximumTotalBytes) bytes.",
                    pointer: "/files"
                )
            }
            total = newTotal
            guard value.sha256.count == 64,
                  value.sha256 == value.sha256.lowercased(),
                  value.sha256.allSatisfy(\.isHexDigit) else {
                throw APIServiceError.validation(
                    "Expected a lowercase SHA-256 digest.",
                    pointer: "/files/\(index)/sha256"
                )
            }
            if path != "manifest.json", !path.hasPrefix("media/") {
                topLevelDataFiles += 1
            }
            declarations.append(APIVocabularyImportFile(
                id: value.id,
                path: path,
                byteSize: value.byteSize,
                sha256: value.sha256,
                uploaded: false
            ))
        }
        guard paths.contains("manifest.json") else {
            throw APIServiceError.validation("manifest.json is required.", pointer: "/files")
        }
        guard topLevelDataFiles == 1 else {
            throw APIServiceError.validation(
                "Exactly one top-level database file is required.", pointer: "/files"
            )
        }
        return declarations.sorted { $0.path < $1.path }
    }

    private func validateDeclaredPath(_ value: String, pointer: String) throws -> String {
        guard value == value.precomposedStringWithCanonicalMapping,
              !value.isEmpty,
              value.utf8.count <= Self.maximumIdentifierBytes,
              !value.hasPrefix("/"), !value.contains("\\"),
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw APIServiceError.validation("Expected a safe normalized relative path.", pointer: pointer)
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }),
              value == "manifest.json"
                || components.count == 1
                || components.first == "media" && components.count > 1 else {
            throw APIServiceError.validation("Expected a safe vocabulary package path.", pointer: pointer)
        }
        return value
    }

    private func validateIdentifier(_ value: String, pointer: String) throws -> String {
        try validateQueryValue(value, pointer: pointer)
    }

    private func validateQueryValue(_ value: String, pointer: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= Self.maximumIdentifierBytes,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw APIServiceError.validation(
                "Value must be non-empty and no larger than \(Self.maximumIdentifierBytes) UTF-8 bytes.",
                pointer: pointer
            )
        }
        return value
    }

    private func loadJobsIfNeeded() throws {
        guard !jobsLoaded else { return }
        jobsLoaded = true
        guard FileManager.default.fileExists(atPath: stagingRootURL.path) else { return }
        let directories = try FileManager.default.contentsOfDirectory(
            at: stagingRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let data = try Data(contentsOf: directory.appendingPathComponent("job.json"))
            let job = try APIJSON.decoder.decode(APIVocabularyImportJob.self, from: data)
            guard job.id == id.uuidString.lowercased() else { continue }
            jobs[id] = job
        }
    }

    private func purgeExpiredJobs(now: Date = .now) throws {
        let expired = jobs.compactMap { id, job in
            job.state != "completed" && now.timeIntervalSince(job.updatedAt) > jobLifetime ? id : nil
        }
        for id in expired {
            jobs.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: jobDirectory(id))
        }
    }

    private func persist(_ job: APIVocabularyImportJob, id: UUID) throws {
        let url = jobDirectory(id).appendingPathComponent("job.json")
        try APIJSON.encoder.encode(job).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw APIServiceError.validation("Vocabulary staging must be a private directory.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func jobDirectory(_ id: UUID) -> URL {
        stagingRootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func packageDirectory(_ id: UUID) -> URL {
        jobDirectory(id).appendingPathComponent("package.neovocab", isDirectory: true)
    }

    private func vocabularyValidationError(_ error: Error) -> APIServiceError {
        .validation("The vocabulary pack or lookup input is invalid.")
    }

    private func installedLibraryInvalid() -> APIServiceError {
        .problem(
            status: 409,
            code: "vocabulary_library_invalid",
            title: "Vocabulary library invalid",
            detail: "The managed vocabulary library failed integrity validation."
        )
    }

    private func resourceConflict(_ detail: String) -> APIServiceError {
        .problem(status: 409, code: "resource_conflict", title: "Resource conflict", detail: detail)
    }
}

extension NeoAnkiAPIService {
    func listVocabularyPacks(_ request: APIRequest) async throws -> APIResponse {
        guard request.body.isEmpty else {
            throw APIServiceError.validation("Vocabulary pack listing does not accept a body.")
        }
        return try .json(APIVocabularyPackCollection(data: try await vocabularyLibrary.listPacks()))
    }

    func getVocabularyPack(_ id: String) async throws -> APIResponse {
        let (_, representation) = try await vocabularyLibrary.pack(id: id)
        return try .json(representation, headers: ["ETag": etag(representation.revision)])
    }

    func deleteVocabularyPack(_ id: String, request: APIRequest) async throws -> APIResponse {
        let (_, representation) = try await vocabularyLibrary.pack(id: id)
        try requireIfMatch(request, revision: representation.revision)
        try await vocabularyLibrary.deletePack(id: id)
        return APIResponse(status: 204)
    }

    func searchVocabularyEntries(packID: String, request: APIRequest) async throws -> APIResponse {
        guard let query = try singleVocabularyQuery(request, name: "query", required: true) else {
            throw APIServiceError.validation(
                "Vocabulary search query is required.", pointer: "/query/query"
            )
        }
        let modeText = try singleVocabularyQuery(request, name: "mode", required: false) ?? "prefix"
        guard let mode = VocabularySearchMode(rawValue: modeText) else {
            throw APIServiceError.validation(
                "Vocabulary search mode must be exact or prefix.", pointer: "/query/mode"
            )
        }
        let limitText = try singleVocabularyQuery(request, name: "limit", required: false)
        let limit: Int
        if let limitText {
            guard let value = Int(limitText), (1 ... 500).contains(value) else {
                throw APIServiceError.validation(
                    "Vocabulary search limit must be from 1 through 500.", pointer: "/query/limit"
                )
            }
            limit = value
        } else {
            limit = 50
        }
        let language = try singleVocabularyQuery(request, name: "language", required: false)
        let values = try await vocabularyLibrary.search(
            packID: packID,
            query: query,
            mode: mode,
            limit: limit,
            language: language
        )
        return try .json(APIVocabularyEntryCollection(data: values))
    }

    func getVocabularyEntry(packID: String, entryID: String) async throws -> APIResponse {
        try .json(try await vocabularyLibrary.entry(packID: packID, entryID: entryID))
    }

    func vocabularyMedia(packID: String, request: APIRequest, headOnly: Bool) async throws
        -> APIResponse
    {
        if request.header("range") != nil {
            throw APIServiceError.problem(
                status: 416,
                code: "range_not_supported",
                title: "Range not supported",
                detail: "Vocabulary media does not support range requests.",
                headers: ["Accept-Ranges": "none"]
            )
        }
        guard let path = try singleVocabularyQuery(request, name: "path", required: true) else {
            throw APIServiceError.validation(
                "Vocabulary media path is required.", pointer: "/query/path"
            )
        }
        let payload = try await vocabularyLibrary.media(
            packID: packID, path: path, includeBytes: !headOnly
        )
        return APIResponse(
            status: 200,
            headers: [
                "Content-Type": vocabularyContentType(for: payload.fileExtension),
                "Content-Length": String(payload.byteCount),
                "Digest": "sha-256=\(payload.sha256)",
                "Accept-Ranges": "none",
            ],
            body: payload.bytes ?? Data()
        )
    }

    func createVocabularyImport(_ request: APIRequest) async throws -> APIResponse {
        try validateVocabularyImportShape(request.body)
        let input = try APIJSON.decodeStrict(
            CreateVocabularyImportInput.self,
            from: request.body,
            allowedKeys: ["files"]
        )
        let job = try await vocabularyLibrary.createImport(input)
        return try .json(
            status: 201,
            job,
            headers: [
                "ETag": etag(job.revision),
                "Location": "/v1/vocabulary-pack-imports/\(job.id)",
            ]
        )
    }

    func getVocabularyImport(_ id: UUID) async throws -> APIResponse {
        let job = try await vocabularyLibrary.importJob(id: id)
        return try .json(job, headers: ["ETag": etag(job.revision)])
    }

    func uploadVocabularyImportFile(
        jobID: UUID,
        fileID: UUID,
        request: APIRequest
    ) async throws -> APIResponse {
        guard Int64(request.body.count) <= APIVocabularyLibrary.maximumFileBytes else {
            throw APIServiceError.problem(
                status: 413,
                code: "payload_too_large",
                title: "Payload too large",
                detail: "A staged vocabulary file may not exceed 1000000000 bytes."
            )
        }
        let current = try await vocabularyLibrary.importJob(id: jobID)
        try requireIfMatch(request, revision: current.revision)
        let updated = try await vocabularyLibrary.upload(jobID: jobID, fileID: fileID, bytes: request.body)
        return try .json(updated, headers: ["ETag": etag(updated.revision)])
    }

    func validateVocabularyImport(_ id: UUID) async throws -> APIResponse {
        let job = try await vocabularyLibrary.validateImport(id: id)
        return try .json(job, headers: ["ETag": etag(job.revision)])
    }

    func commitVocabularyImport(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        _ = try requiredIdempotencyKey(request)
        let current = try await vocabularyLibrary.importJob(id: id)
        try requireIfMatch(request, revision: current.revision)
        let job = try await vocabularyLibrary.commitImport(id: id)
        var headers = ["ETag": etag(job.revision)]
        if let packID = job.pack?.id {
            headers["Location"] = "/v1/vocabulary-packs/\(encodedVocabularyPathSegment(packID))"
        }
        return try .json(job, headers: headers)
    }

    func deleteVocabularyImport(_ id: UUID, request: APIRequest) async throws -> APIResponse {
        let current = try await vocabularyLibrary.importJob(id: id)
        try requireIfMatch(request, revision: current.revision)
        try await vocabularyLibrary.deleteImport(id: id)
        return APIResponse(status: 204)
    }

    func decodeVocabularyPathSegment(_ value: String, pointer: String) throws -> String {
        guard let decoded = value.removingPercentEncoding,
              !decoded.isEmpty,
              decoded.utf8.count <= APIVocabularyLibrary.maximumIdentifierBytes else {
            throw APIServiceError.validation("The vocabulary path identifier is invalid.", pointer: pointer)
        }
        return decoded
    }

    private func singleVocabularyQuery(
        _ request: APIRequest,
        name: String,
        required: Bool
    ) throws -> String? {
        guard let values = request.query[name] else {
            if required {
                throw APIServiceError.validation(
                    "The \(name) query parameter is required.", pointer: "/query/\(name)",
                    fieldCode: "required"
                )
            }
            return nil
        }
        guard values.count == 1, let value = values.first,
              !value.isEmpty,
              value.utf8.count <= APIVocabularyLibrary.maximumIdentifierBytes else {
            throw APIServiceError.validation(
                "The \(name) query parameter must occur once and be non-empty.",
                pointer: "/query/\(name)"
            )
        }
        return value
    }

    private func validateVocabularyImportShape(_ body: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let files = object["files"] as? [[String: Any]] else {
            throw APIServiceError.validation("The vocabulary import body is invalid.")
        }
        let allowed = Set(["id", "path", "byteSize", "sha256"])
        for (index, file) in files.enumerated() {
            if let unknown = Set(file.keys).subtracting(allowed).sorted().first {
                throw APIServiceError.validation(
                    "Unknown request member.",
                    pointer: "/files/\(index)/\(unknown)",
                    fieldCode: "unknown_member"
                )
            }
        }
    }

    private func vocabularyContentType(for fileExtension: String) -> String {
        switch fileExtension {
        case "aac": "audio/aac"
        case "caf": "audio/x-caf"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        default: "application/octet-stream"
        }
    }

    private func encodedVocabularyPathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
