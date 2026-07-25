import CryptoKit
import Foundation

/// Content-addressed media storage scoped to a sandbox directory.
public actor MediaStore {
    public let rootDirectory: URL

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(
            at: rootDirectory.appendingPathComponent("media", isDirectory: true),
            withIntermediateDirectories: true
        )
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

        let data = try Data(contentsOf: resolved)
        let ext = resolved.pathExtension.lowercased().isEmpty
            ? MediaValidation.defaultExtension(for: kind)
            : resolved.pathExtension.lowercased()
        try MediaValidation.validate(data: data, kind: kind, fileExtension: ext)

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
        let ext = fileExtension.lowercased()
        try MediaValidation.validate(data: data, kind: kind, fileExtension: ext)

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
        if let legacy = ref.legacyURL {
            return try resolveLegacyURL(legacy)
        }

        let fileName = "\(ref.assetHash).\(ref.fileExtension)"
        let url = mediaDirectory.appendingPathComponent(fileName).standardizedFileURL
        guard url.path.hasPrefix(mediaDirectory.standardizedFileURL.path) else {
            throw MediaError.sandboxViolation
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaError.readFailed
        }
        return url
    }

    private func resolveLegacyURL(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL
        guard resolved.isFileURL, FileManager.default.fileExists(atPath: resolved.path) else {
            throw MediaError.readFailed
        }
        return resolved
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
