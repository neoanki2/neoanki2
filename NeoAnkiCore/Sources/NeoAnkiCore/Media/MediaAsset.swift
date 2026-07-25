import Foundation

/// Database metadata for one content-addressed media object.
public struct MediaAsset: Equatable, Sendable {
    public let hash: String
    public let kind: MediaKind
    public let byteSize: Int
    public let fileExtension: String
    public let createdAt: Date
    public let refCount: Int

    public init(
        hash: String,
        kind: MediaKind,
        byteSize: Int,
        fileExtension: String,
        createdAt: Date,
        refCount: Int
    ) {
        self.hash = hash
        self.kind = kind
        self.byteSize = byteSize
        self.fileExtension = fileExtension
        self.createdAt = createdAt
        self.refCount = refCount
    }
}

struct MediaAssetDescriptor: Equatable, Sendable {
    let hash: String
    let kind: MediaKind
    let byteSize: Int
    let fileExtension: String
}
