import CryptoKit
import Foundation

/// Content-addressed media storage scoped to a sandbox directory.
public actor MediaStore {
    public let rootDirectory: URL

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
    public func ingest(url: URL, kind: MediaKind, altText: String? = nil) throws -> MediaRef {
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

        let hash = Self.sha256Hex(data)
        let destination = mediaDirectory.appendingPathComponent("\(hash).\(ext)")

        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }

        return MediaRef(
            kind: kind,
            assetHash: hash,
            fileExtension: ext,
            altText: altText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// Ingests raw data (e.g. import base64) into the sandbox.
    public func ingest(data: Data, kind: MediaKind, fileExtension: String, altText: String? = nil) throws -> MediaRef {
        let ext = try MediaValidation.validatedExtension(
            data: data,
            kind: kind,
            fileExtension: fileExtension
        )

        let hash = Self.sha256Hex(data)
        let destination = mediaDirectory.appendingPathComponent("\(hash).\(ext)")

        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }

        return MediaRef(
            kind: kind,
            assetHash: hash,
            fileExtension: ext,
            altText: altText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// Resolves a ref to a file URL inside the sandbox. Rejects paths outside mediaDirectory.
    public func resolve(_ ref: MediaRef) throws -> URL {
        guard ref.isValidStoredReference else {
            throw MediaError.sandboxViolation
        }

        let fileName = "\(ref.assetHash).\(ref.fileExtension)"
        let base = mediaDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = mediaDirectory
            .appendingPathComponent(fileName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard Self.isContained(url, in: base) else {
            throw MediaError.sandboxViolation
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaError.readFailed
        }
        return url
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

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
