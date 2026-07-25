import Foundation

/// A reference to a stored media asset. Bytes live in a content-addressed
/// media store; the model only keeps this lightweight, serializable handle.
public struct MediaRef: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var kind: MediaKind
    /// SHA-256 hex digest of stored bytes.
    public var assetHash: String
    public var fileExtension: String
    /// Duration for time-based media, enabling clip/segment playback.
    public var durationMs: Int?
    /// Accessibility / fallback description.
    public var altText: String?
    /// Ephemeral GC handoff. It is deliberately excluded from Codable and is
    /// consumed atomically when an item commit adopts this reference.
    var reservationID: UUID?

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        assetHash: String,
        fileExtension: String,
        durationMs: Int? = nil,
        altText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.assetHash = assetHash
        self.fileExtension = fileExtension
        self.durationMs = durationMs
        self.altText = altText
        reservationID = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, assetHash, fileExtension, durationMs, altText, url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.url) {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "Direct file URLs are not supported media references."
            )
        }

        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(MediaKind.self, forKey: .kind)
        assetHash = try container.decode(String.self, forKey: .assetHash)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        altText = try container.decodeIfPresent(String.self, forKey: .altText)
        reservationID = nil
        guard isValidStoredReference else {
            throw DecodingError.dataCorruptedError(
                forKey: .assetHash,
                in: container,
                debugDescription: "Media references must use a SHA-256 hash and allowed extension."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValidStoredReference else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Media references must use a SHA-256 hash and allowed extension."
                )
            )
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(assetHash, forKey: .assetHash)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encodeIfPresent(altText, forKey: .altText)
    }

    var isValidStoredReference: Bool {
        assetHash.count == 64
            && assetHash.allSatisfy { "0123456789abcdef".contains($0) }
            && fileExtension == fileExtension.lowercased()
            && MediaValidation.allowedExtensions(for: kind).contains(fileExtension)
    }

    public static func == (lhs: MediaRef, rhs: MediaRef) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.assetHash == rhs.assetHash
            && lhs.fileExtension == rhs.fileExtension
            && lhs.durationMs == rhs.durationMs
            && lhs.altText == rhs.altText
    }
}

public enum MediaKind: String, Codable, Sendable {
    case audio
    case image
    case gif
    case video
}

public extension FieldType {
    var mediaKind: MediaKind? {
        switch self {
        case .audio: .audio
        case .image: .image
        case .gif: .gif
        case .video: .video
        default: nil
        }
    }
}
