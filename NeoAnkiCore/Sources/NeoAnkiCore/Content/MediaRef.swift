import Foundation

/// A reference to a stored media asset. The bytes live in a content-addressed
/// media store; the model only keeps this lightweight, serializable handle.
public struct MediaRef: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var kind: MediaKind
    public var url: URL
    /// Duration for time-based media, enabling clip/segment playback.
    public var durationMs: Int?
    /// Accessibility / fallback description.
    public var altText: String?

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        url: URL,
        durationMs: Int? = nil,
        altText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.durationMs = durationMs
        self.altText = altText
    }
}

public enum MediaKind: String, Codable, Sendable {
    case audio
    case image
    case gif
    case video
}
