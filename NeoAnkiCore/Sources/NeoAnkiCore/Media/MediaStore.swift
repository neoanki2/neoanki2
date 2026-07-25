import CryptoKit
import Foundation

/// Content-addressed media storage scoped to a sandbox directory.
public actor MediaStore {
    public let rootDirectory: URL
    private var metadataDatabase: SQLiteDatabase?

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        let mediaDirectory = rootDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let resolvedRoot = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedMedia = mediaDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isContained(resolvedMedia, in: resolvedRoot) else {
            throw MediaError.sandboxViolation
        }
    }

    public static func defaultRoot(near databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent()
    }

    private var mediaDirectory: URL {
        rootDirectory.appendingPathComponent("media", isDirectory: true)
    }

    /// Ingests bytes from a user-selected file into the sandbox and returns a hash-based ref.
    public func ingest(url: URL, kind: MediaKind, altText: String? = nil) async throws -> MediaRef {
        let resolved = url.standardizedFileURL
        guard resolved.isFileURL else {
            throw MediaError.invalidPath
        }

        let maxBytes = MediaValidation.maxBytes(for: kind)
        let data = try readFile(at: resolved, kind: kind, maxBytes: maxBytes)
        let claimedExtension = resolved.pathExtension.lowercased().isEmpty
            ? MediaValidation.defaultExtension(for: kind)
            : resolved.pathExtension.lowercased()
        let ext = try MediaValidation.validatedExtension(
            data: data,
            kind: kind,
            fileExtension: claimedExtension
        )

        return try await store(data, kind: kind, fileExtension: ext, altText: altText)
    }

    /// Ingests raw data (e.g. import base64) into the sandbox.
    public func ingest(
        data: Data,
        kind: MediaKind,
        fileExtension: String,
        altText: String? = nil
    ) async throws -> MediaRef {
        let ext = try MediaValidation.validatedExtension(
            data: data,
            kind: kind,
            fileExtension: fileExtension
        )

        return try await store(data, kind: kind, fileExtension: ext, altText: altText)
    }

    private func store(
        _ data: Data,
        kind: MediaKind,
        fileExtension: String,
        altText: String?
    ) async throws -> MediaRef {
        let hash = Self.sha256Hex(data)
        var storedExtension = fileExtension
        if let metadataDatabase,
           let existing = try await metadataDatabase.fetchMediaAsset(hash: hash)
        {
            guard MediaValidation.allowedExtensions(for: kind).contains(existing.fileExtension) else {
                throw MediaError.unsupportedFormat(kind)
            }
            storedExtension = existing.fileExtension
        }
        let destination = try assetURL(hash: hash, fileExtension: storedExtension, kind: kind)

        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        } else {
            _ = try containedExistingURL(destination)
        }

        let ref = MediaRef(
            kind: kind,
            assetHash: hash,
            fileExtension: storedExtension,
            altText: altText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        if let metadataDatabase {
            try await metadataDatabase.registerMediaAsset(
                MediaAssetDescriptor(
                    hash: hash,
                    kind: kind,
                    byteSize: data.count,
                    fileExtension: storedExtension
                ),
                createdAt: .now
            )
        }
        return ref
    }

    func attachMetadataDatabase(_ database: SQLiteDatabase) {
        metadataDatabase = database
    }

    /// Resolves a ref to a file URL inside the sandbox. Rejects paths outside mediaDirectory.
    public func resolve(_ ref: MediaRef) throws -> URL {
        guard ref.isValidStoredReference else {
            throw MediaError.sandboxViolation
        }

        let url = try assetURL(hash: ref.assetHash, fileExtension: ref.fileExtension, kind: ref.kind)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaError.readFailed
        }
        return try containedExistingURL(url)
    }

    func descriptor(for ref: MediaRef) throws -> MediaAssetDescriptor {
        guard ref.legacyURL == nil else { throw MediaError.invalidPath }
        let url = try resolve(ref)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let byteSize = values.fileSize else {
            throw MediaError.readFailed
        }
        return MediaAssetDescriptor(
            hash: ref.assetHash,
            kind: ref.kind,
            byteSize: byteSize,
            fileExtension: canonicalExtension(ref.fileExtension.lowercased())
        )
    }

    /// Removes an orphan using only validated content-addressed components.
    /// Missing files are already collected and therefore count as success.
    func removeOrphan(_ asset: MediaAsset) throws {
        guard asset.refCount == 0 else { return }
        let url = try assetURL(
            hash: asset.hash,
            fileExtension: asset.fileExtension,
            kind: asset.kind
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = try containedExistingURL(url)
        try FileManager.default.removeItem(at: url)
    }

    private func readFile(at url: URL, kind: MediaKind, maxBytes: Int) throws -> Data {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw MediaError.readFailed
        }

        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MediaError.invalidPath
        }
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(maxBytes) {
            throw MediaError.fileTooLarge(kind, maxBytes: maxBytes)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw MediaError.readFailed
        }
        defer {
            try? handle.close()
        }

        var data = Data()
        data.reserveCapacity(min((attributes[.size] as? NSNumber)?.intValue ?? 0, maxBytes))
        do {
            while data.count <= maxBytes {
                let remaining = maxBytes - data.count + 1
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else {
                    return data
                }
                data.append(chunk)
            }
        } catch {
            throw MediaError.readFailed
        }
        throw MediaError.fileTooLarge(kind, maxBytes: maxBytes)
    }

    private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let baseComponents = directory.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > baseComponents.count
            && candidateComponents.prefix(baseComponents.count).elementsEqual(baseComponents)
    }

    private func assetURL(hash: String, fileExtension: String, kind: MediaKind) throws -> URL {
        let ext = fileExtension.lowercased()
        guard hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              MediaValidation.allowedExtensions(for: kind).contains(ext)
        else {
            throw MediaError.sandboxViolation
        }

        let base = mediaDirectory.standardizedFileURL
        let url = base.appendingPathComponent("\(hash).\(ext)", isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == base else {
            throw MediaError.sandboxViolation
        }
        return url
    }

    private func containedExistingURL(_ url: URL) throws -> URL {
        let base = mediaDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == base else {
            throw MediaError.sandboxViolation
        }
        return resolved
    }

    private func canonicalExtension(_ fileExtension: String) -> String {
        fileExtension == "jpeg" ? "jpg" : fileExtension
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
