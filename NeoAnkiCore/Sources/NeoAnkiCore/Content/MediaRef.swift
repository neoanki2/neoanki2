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
    /// Legacy test fixtures may still carry a direct file URL.
    public var legacyURL: URL?

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        assetHash: String,
        fileExtension: String,
        durationMs: Int? = nil,
        altText: String? = nil,
        legacyURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.assetHash = assetHash
        self.fileExtension = fileExtension
        self.durationMs = durationMs
        self.altText = altText
        self.legacyURL = legacyURL
    }

    /// Convenience for tests and migration from URL-based refs.
    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        url: URL,
        durationMs: Int? = nil,
        altText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.assetHash = ""
        self.fileExtension = url.pathExtension.lowercased()
        self.durationMs = durationMs
        self.altText = altText
        self.legacyURL = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, assetHash, fileExtension, durationMs, altText, url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(MediaKind.self, forKey: .kind)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        altText = try container.decodeIfPresent(String.self, forKey: .altText)

        if let hash = try container.decodeIfPresent(String.self, forKey: .assetHash), !hash.isEmpty {
            assetHash = hash
            fileExtension = try container.decode(String.self, forKey: .fileExtension)
            legacyURL = nil
        } else if let url = try container.decodeIfPresent(URL.self, forKey: .url) {
            assetHash = ""
            fileExtension = url.pathExtension.lowercased()
            legacyURL = url
        } else {
            assetHash = try container.decode(String.self, forKey: .assetHash)
            fileExtension = try container.decode(String.self, forKey: .fileExtension)
            legacyURL = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encodeIfPresent(altText, forKey: .altText)

        if let legacyURL, assetHash.isEmpty {
            try container.encode(legacyURL, forKey: .url)
        } else {
            try container.encode(assetHash, forKey: .assetHash)
            try container.encode(fileExtension, forKey: .fileExtension)
        }
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
