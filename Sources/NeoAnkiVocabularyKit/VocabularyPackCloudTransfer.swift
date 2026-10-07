import CryptoKit
import Foundation

/// Immutable catalog entries identify a whole validated pack, independently of its local folder.
public struct CloudVocabularyPack: Codable, Equatable, Sendable, Identifiable {
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var byteCount: Int64
        public var sha256: String
        public init(path: String, byteCount: Int64, sha256: String) {
            self.path = path; self.byteCount = byteCount; self.sha256 = sha256
        }
    }
    public var id: String
    public var manifest: VocabularyPackManifest
    public var files: [File]
    public var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    // Eight MiB bounds memory and individual CKAssets even for multi-gigabyte dictionaries.
    public static let chunkBytes = 8 * 1_024 * 1_024
    public static let maximumCatalogEntryBytes = 900_000

    public init(manifest: VocabularyPackManifest, files: [File]) throws {
        self.manifest = manifest
        self.files = files
        id = Self.digest(try Self.manifestData(manifest))
    }

    public func chunkID(file: Int, chunk: Int64) -> String { "\(id)-\(file)-\(chunk)" }

    public func validate() throws {
        let limits = VocabularyPackLimits.default
        let data = try Self.manifestData(manifest)
        guard manifest.format == "neoanki-vocabulary-pack",
              manifest.formatVersion == VocabularyPackManifest.currentFormatVersion,
              FileSafety.isSafeSingleFilename(manifest.databaseFile),
              manifest.entryCount >= 0, manifest.entryCount <= limits.maximumEntries,
              data.count <= limits.maximumManifestBytes,
              id == Self.digest(data), manifest.mediaFiles.count <= limits.maximumMediaFiles,
              files.count == manifest.mediaFiles.count + 2,
              try JSONEncoder().encode(self).count <= Self.maximumCatalogEntryBytes else {
            throw invalid("Unsupported dictionary catalog entry.")
        }
        let expected = ["manifest.json", manifest.databaseFile] + manifest.mediaFiles.sorted { $0.path < $1.path }.map { "media/" + $0.path }
        guard files.map(\.path) == expected, Set(expected).count == expected.count else {
            throw invalid("Dictionary file list does not match its manifest.")
        }
        var total: Int64 = 0
        for file in files {
            guard FileSafety.isSafeRelativePath(file.path), FileSafety.isSHA256Hex(file.sha256),
                  file.byteCount >= 0, file.byteCount <= limits.maximumPackBytes else {
                throw invalid("Unsafe dictionary file.")
            }
            total += file.byteCount
            guard total <= limits.maximumPackBytes else { throw invalid("Dictionary is too large.") }
        }
        guard files[0].sha256 == Self.digest(data), files[0].byteCount == Int64(data.count),
              files[1].sha256 == manifest.databaseSHA256.lowercased() else {
            throw invalid("Dictionary checksums do not match its manifest.")
        }
        for (file, media) in zip(files.dropFirst(2), manifest.mediaFiles.sorted { $0.path < $1.path }) {
            guard file.sha256 == media.sha256.lowercased(), file.byteCount == media.byteSize else {
                throw invalid("Dictionary media does not match its manifest.")
            }
        }
    }

    /// Sets have nondeterministic Codable order; normalize them before deriving cross-device identity.
    public static func manifestData(_ manifest: VocabularyPackManifest) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        object["capabilities"] = manifest.capabilities.map(\.rawValue).sorted()
        object["mediaFiles"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest.mediaFiles.sorted { $0.path < $1.path }))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func invalid(_ message: String) -> VocabularyPackError { .invalidPackage(message) }
}

/// Catalog fetching must never fetch chunk assets. Implementations store chunks under deterministic IDs.
public protocol VocabularyPackCloudTransport: Sendable {
    func accountIdentifier() async throws -> String
    func catalog() async throws -> [CloudVocabularyPack]
    func publish(_ pack: CloudVocabularyPack) async throws
    func uploadChunk(id: String, data: Data) async throws
    func downloadChunk(id: String, maximumBytes: Int) async throws -> Data
}

public actor VocabularyPackCloudTransfer {
    public init() {}

    public func describe(at package: URL) throws -> CloudVocabularyPack {
        let manifestURL = package.appendingPathComponent("manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= VocabularyPackLimits.default.maximumManifestBytes else {
            throw VocabularyPackError.invalidPackage("Dictionary manifest is too large.")
        }
        let manifest = try JSONDecoder().decode(VocabularyPackManifest.self, from: Data(contentsOf: manifestURL))
        guard FileSafety.isSafeSingleFilename(manifest.databaseFile) else {
            throw VocabularyPackError.invalidPackage("Unsafe dictionary database filename.")
        }
        let data = try CloudVocabularyPack.manifestData(manifest)
        var files = [CloudVocabularyPack.File(path: "manifest.json", byteCount: Int64(data.count), sha256: CloudVocabularyPack.digest(data))]
        let databaseSize = try package.appendingPathComponent(manifest.databaseFile).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        files.append(.init(path: manifest.databaseFile, byteCount: Int64(databaseSize), sha256: manifest.databaseSHA256.lowercased()))
        files += manifest.mediaFiles.sorted { $0.path < $1.path }.map { .init(path: "media/" + $0.path, byteCount: $0.byteSize, sha256: $0.sha256.lowercased()) }
        let descriptor = try CloudVocabularyPack(manifest: manifest, files: files)
        try descriptor.validate()
        return descriptor
    }

    public func upload(_ pack: CloudVocabularyPack, from package: URL, transport: any VocabularyPackCloudTransport,
                       progress: @Sendable (Int64, Int64) -> Void) async throws {
        try pack.validate()
        let opened = try await VocabularyPack.open(at: package)
        guard try CloudVocabularyPack.manifestData(opened.manifest) == CloudVocabularyPack.manifestData(pack.manifest) else {
            throw VocabularyPackError.invalidPackage("Dictionary changed during upload.")
        }
        var completed: Int64 = 0
        for (index, file) in pack.files.enumerated() {
            let manifest = index == 0 ? try CloudVocabularyPack.manifestData(pack.manifest) : nil
            let handle = index == 0 ? nil : try FileHandle(forReadingFrom: package.appendingPathComponent(file.path))
            defer { try? handle?.close() }
            var offset: Int64 = 0
            var hasher = SHA256()
            while offset < file.byteCount {
                try Task.checkCancellation()
                let count = Int(min(Int64(CloudVocabularyPack.chunkBytes), file.byteCount - offset))
                let bytes = try manifest.map { Data($0[Int(offset)..<Int(offset) + count]) } ?? handle!.read(upToCount: count) ?? Data()
                guard bytes.count == count else { throw VocabularyPackError.invalidPackage("Dictionary changed during upload.") }
                hasher.update(data: bytes)
                try await transport.uploadChunk(id: pack.chunkID(file: index, chunk: offset / Int64(CloudVocabularyPack.chunkBytes)), data: bytes)
                offset += Int64(count); completed += Int64(count)
                progress(completed, pack.byteCount)
            }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw VocabularyPackError.invalidPackage("Dictionary changed during upload.")
            }
        }
        try Task.checkCancellation()
        // Publishing last prevents other devices from offering incomplete uploads.
        try await transport.publish(pack)
    }

    public func download(_ pack: CloudVocabularyPack, into root: URL, transport: any VocabularyPackCloudTransport,
                         progress: @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try pack.validate()
        let staging = root.appendingPathComponent(".download-\(pack.id).neovocab", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for (index, file) in pack.files.enumerated() {
            try Task.checkCancellation()
            let url = staging.appendingPathComponent(file.path)
            try checkLocalPath(url, inside: staging)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw VocabularyPackError.ioFailure("Could not create the dictionary download.")
                }
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            var offset = min(Int64(min(size, UInt64(file.byteCount))), file.byteCount)
            if offset == file.byteCount {
                if try SHA256File.hexDigest(of: url) != file.sha256 { offset = 0 }
            } else {
                offset -= offset % Int64(CloudVocabularyPack.chunkBytes)
            }
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: UInt64(offset))
            completed += offset; progress(completed, pack.byteCount)
            while offset < file.byteCount {
                try Task.checkCancellation()
                let count = Int(min(Int64(CloudVocabularyPack.chunkBytes), file.byteCount - offset))
                let bytes = try await transport.downloadChunk(id: pack.chunkID(file: index, chunk: offset / Int64(CloudVocabularyPack.chunkBytes)), maximumBytes: count)
                try Task.checkCancellation()
                guard bytes.count == count else { throw VocabularyPackError.invalidPackage("Incomplete dictionary download. Try again.") }
                try handle.write(contentsOf: bytes)
                try handle.synchronize()
                offset += Int64(count); completed += Int64(count)
                progress(completed, pack.byteCount)
            }
            guard try SHA256File.hexDigest(of: url) == file.sha256 else {
                try handle.truncate(atOffset: 0)
                throw VocabularyPackError.invalidPackage("Dictionary download failed its checksum. Try again.")
            }
        }
        let opened = try await VocabularyPack.open(at: staging)
        guard try CloudVocabularyPack.manifestData(opened.manifest) == CloudVocabularyPack.manifestData(pack.manifest) else {
            throw VocabularyPackError.invalidPackage("Downloaded dictionary does not match its catalog entry.")
        }
        return staging
    }

    private func checkLocalPath(_ url: URL, inside root: URL) throws {
        var current = url
        while current.path.count >= root.path.count {
            if FileManager.default.fileExists(atPath: current.path),
               try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw VocabularyPackError.invalidPackage("Dictionary download contains a symbolic link.")
            }
            if current == root { return }
            current.deleteLastPathComponent()
        }
        throw VocabularyPackError.invalidPackage("Unsafe dictionary download path.")
    }
}
