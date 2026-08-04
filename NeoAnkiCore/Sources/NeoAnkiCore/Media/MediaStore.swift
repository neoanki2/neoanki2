import CryptoKit
import Foundation

/// Content-addressed media storage scoped to a sandbox directory.
public actor MediaStore {
    static let reservationLifetime: TimeInterval = 24 * 60 * 60
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

        return try await store(
            data,
            kind: kind,
            fileExtension: ext,
            altText: altText,
            reservationScope: nil
        )
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

        return try await store(
            data,
            kind: kind,
            fileExtension: ext,
            altText: altText,
            reservationScope: nil
        )
    }

    func ingest(
        url: URL,
        kind: MediaKind,
        reservationScope: UUID
    ) async throws -> MediaRef {
        let resolved = url.standardizedFileURL
        guard resolved.isFileURL else { throw MediaError.invalidPath }
        let data = try readFile(
            at: resolved,
            kind: kind,
            maxBytes: MediaValidation.maxBytes(for: kind)
        )
        let claimedExtension = resolved.pathExtension.lowercased().isEmpty
            ? MediaValidation.defaultExtension(for: kind)
            : resolved.pathExtension.lowercased()
        let ext = try MediaValidation.validatedExtension(
            data: data,
            kind: kind,
            fileExtension: claimedExtension
        )
        return try await store(
            data,
            kind: kind,
            fileExtension: ext,
            altText: nil,
            reservationScope: reservationScope
        )
    }

    func ingest(
        data: Data,
        kind: MediaKind,
        fileExtension: String,
        altText: String? = nil,
        reservationScope: UUID
    ) async throws -> MediaRef {
        let ext = try MediaValidation.validatedExtension(
            data: data,
            kind: kind,
            fileExtension: fileExtension
        )
        return try await store(
            data,
            kind: kind,
            fileExtension: ext,
            altText: altText,
            reservationScope: reservationScope
        )
    }

    /// Adopts a portable-deck staging file without materializing it as `Data`.
    /// The file is re-hashed immediately before adoption to close the gap
    /// between package validation and destination publication.
    func ingestVerifiedPortableFile(
        url: URL,
        expected: MediaAssetDescriptor,
        kind: MediaKind,
        reservationScope: UUID
    ) async throws -> MediaRef {
        guard kind == expected.kind,
              expected.byteSize >= 0,
              expected.byteSize <= MediaValidation.maxBytes(for: kind),
              expected.hash.count == 64,
              expected.hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw MediaError.unsupportedFormat(kind) }

        let verified = try verifyFile(
            at: url.standardizedFileURL,
            kind: kind,
            fileExtension: expected.fileExtension,
            maximumBytes: expected.byteSize
        )
        guard verified.byteSize == expected.byteSize, verified.hash == expected.hash else {
            throw MediaError.readFailed
        }

        var storedExtension = expected.fileExtension
        if let metadataDatabase,
           let existing = try await metadataDatabase.fetchMediaAsset(hash: expected.hash)
        {
            guard existing.kind == kind,
                  existing.byteSize == expected.byteSize,
                  MediaValidation.allowedExtensions(for: kind).contains(existing.fileExtension)
            else { throw MediaError.unsupportedFormat(kind) }
            storedExtension = existing.fileExtension
        }
        let descriptor = MediaAssetDescriptor(
            hash: expected.hash,
            kind: kind,
            byteSize: expected.byteSize,
            fileExtension: storedExtension
        )
        let reservationID = UUID()
        let createdAsset: Bool
        if let metadataDatabase {
            let now = Date.now
            createdAsset = try await metadataDatabase.reserveMediaAsset(
                descriptor,
                reservationID: reservationID,
                scopeID: reservationScope,
                createdAt: now,
                expiresAt: now.addingTimeInterval(Self.reservationLifetime)
            )
        } else {
            createdAsset = false
        }

        let destination = try assetURL(
            hash: expected.hash,
            fileExtension: storedExtension,
            kind: kind
        )
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                let temporary = mediaDirectory.appendingPathComponent(
                    ".\(UUID().uuidString).portable-media",
                    isDirectory: false
                )
                defer { try? FileManager.default.removeItem(at: temporary) }
                try copyFileInChunks(from: url, to: temporary, expectedBytes: expected.byteSize)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } else {
                let existingURL = try containedExistingURL(destination)
                let existing = try verifyFile(
                    at: existingURL,
                    kind: kind,
                    fileExtension: storedExtension,
                    maximumBytes: expected.byteSize
                )
                guard existing.hash == expected.hash else {
                    throw MediaError.readFailed
                }
            }
        } catch {
            if let metadataDatabase,
               let asset = try? await metadataDatabase.cancelMediaReservation(
                   id: reservationID,
                   deleteNewAsset: createdAsset
               )
            {
                try? removeAssetFile(asset)
            }
            throw error
        }

        var ref = MediaRef(
            kind: kind,
            assetHash: expected.hash,
            fileExtension: storedExtension
        )
        if metadataDatabase != nil { ref.reservationID = reservationID }
        return ref
    }

    /// Ingests raw data after deriving its format from validated bytes.
    public func ingest(
        data: Data,
        kind: MediaKind,
        altText: String? = nil
    ) async throws -> MediaRef {
        let ext = try MediaValidation.inferredExtension(data: data, expectedKind: kind)
        return try await store(
            data,
            kind: kind,
            fileExtension: ext,
            altText: altText,
            reservationScope: nil
        )
    }

    func ingest(
        data: Data,
        kind: MediaKind,
        altText: String?,
        reservationID: UUID,
        reservationScope: UUID
    ) async throws -> MediaRef {
        let ext = try MediaValidation.inferredExtension(data: data, expectedKind: kind)
        return try await store(
            data,
            kind: kind,
            fileExtension: ext,
            altText: altText,
            reservationScope: reservationScope,
            reservationID: reservationID
        )
    }

    private func store(
        _ data: Data,
        kind: MediaKind,
        fileExtension: String,
        altText: String?,
        reservationScope: UUID?,
        reservationID: UUID = UUID()
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
        let descriptor = MediaAssetDescriptor(
            hash: hash,
            kind: kind,
            byteSize: data.count,
            fileExtension: storedExtension
        )
        let createdAsset: Bool
        if let metadataDatabase {
            let now = Date.now
            createdAsset = try await metadataDatabase.reserveMediaAsset(
                descriptor,
                reservationID: reservationID,
                scopeID: reservationScope,
                createdAt: now,
                expiresAt: now.addingTimeInterval(Self.reservationLifetime)
            )
        } else {
            createdAsset = false
        }
        let destination = try assetURL(hash: hash, fileExtension: storedExtension, kind: kind)

        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            } else {
                _ = try containedExistingURL(destination)
            }
        } catch {
            if let metadataDatabase,
               let asset = try? await metadataDatabase.cancelMediaReservation(
                   id: reservationID,
                   deleteNewAsset: createdAsset
               )
            {
                try? removeAssetFile(asset)
            }
            throw error
        }

        var ref = MediaRef(
            kind: kind,
            assetHash: hash,
            fileExtension: storedExtension,
            altText: altText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        if metadataDatabase != nil {
            ref.reservationID = reservationID
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
        try removeAssetFile(asset)
    }

    func rollbackReservations(scopeID: UUID) async throws {
        guard let metadataDatabase else { return }
        let assets = try await metadataDatabase.rollbackMediaReservations(scopeID: scopeID)
        for asset in assets {
            try removeAssetFile(asset)
        }
    }

    func releaseReservations(scopeID: UUID) async throws {
        try await metadataDatabase?.releaseMediaReservations(scopeID: scopeID)
    }

    private func removeAssetFile(_ asset: MediaAsset) throws {
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

    private func verifyFile(
        at url: URL,
        kind: MediaKind,
        fileExtension: String,
        maximumBytes: Int
    ) throws -> (hash: String, byteSize: Int) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true,
              let size = values.fileSize, size == maximumBytes
        else { throw MediaError.invalidPath }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var prefix = Data()
        var count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += chunk.count
            guard count <= maximumBytes else {
                throw MediaError.fileTooLarge(kind, maxBytes: maximumBytes)
            }
            if prefix.count < 64 {
                prefix.append(chunk.prefix(64 - prefix.count))
            }
            hasher.update(data: chunk)
        }
        _ = try MediaValidation.validatedExtension(
            data: prefix,
            kind: kind,
            fileExtension: fileExtension
        )
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            count
        )
    }

    private func copyFileInChunks(from source: URL, to destination: URL, expectedBytes: Int) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var count = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += chunk.count
            guard count <= expectedBytes else { throw MediaError.readFailed }
            try output.write(contentsOf: chunk)
        }
        guard count == expectedBytes else { throw MediaError.readFailed }
        try output.synchronize()
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
