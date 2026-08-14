import Foundation

/// A persistent, local-only learner recording submitted from an Audio
/// Submission card. It is deliberately independent of review history.
public struct StudyResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let cardID: UUID
    public let itemID: UUID
    public let mediaHash: String
    public let fileExtension: String
    public let byteSize: Int
    public let durationMilliseconds: Int
    public let capturedAt: Date
    public let submittedAt: Date
    public let sourceTitle: String

    public init(
        id: UUID,
        cardID: UUID,
        itemID: UUID,
        mediaHash: String,
        fileExtension: String,
        byteSize: Int,
        durationMilliseconds: Int,
        capturedAt: Date,
        submittedAt: Date,
        sourceTitle: String
    ) {
        self.id = id
        self.cardID = cardID
        self.itemID = itemID
        self.mediaHash = mediaHash
        self.fileExtension = fileExtension
        self.byteSize = byteSize
        self.durationMilliseconds = durationMilliseconds
        self.capturedAt = capturedAt
        self.submittedAt = submittedAt
        self.sourceTitle = sourceTitle
    }
}

public struct StudyResponseQuery: Sendable, Equatable {
    public var cardID: UUID?
    public var itemID: UUID?
    public var tag: String?
    public var createdAfter: Date?
    public var submittedBefore: Date?
    public var submittedBeforeID: UUID?
    public var limit: Int

    public init(
        cardID: UUID? = nil,
        itemID: UUID? = nil,
        tag: String? = nil,
        createdAfter: Date? = nil,
        submittedBefore: Date? = nil,
        submittedBeforeID: UUID? = nil,
        limit: Int = 100
    ) {
        self.cardID = cardID
        self.itemID = itemID
        self.tag = tag
        self.createdAfter = createdAfter
        self.submittedBefore = submittedBefore
        self.submittedBeforeID = submittedBeforeID
        self.limit = limit
    }
}

public struct StudyResponseDraft: Sendable, Equatable {
    public let id: UUID
    public let cardID: UUID
    public let fileURL: URL
    public let durationMilliseconds: Int
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        fileURL: URL,
        durationMilliseconds: Int,
        capturedAt: Date
    ) {
        self.id = id
        self.cardID = cardID
        self.fileURL = fileURL
        self.durationMilliseconds = durationMilliseconds
        self.capturedAt = capturedAt
    }
}
