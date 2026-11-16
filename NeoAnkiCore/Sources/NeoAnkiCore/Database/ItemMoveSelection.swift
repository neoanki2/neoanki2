import Foundation

/// The assignment the learner selected, without copying editable item content.
public struct ItemMoveSelection: Sendable, Equatable {
    public let itemID: UUID
    public let expectedDeckID: UUID?

    public init(itemID: UUID, expectedDeckID: UUID?) {
        self.itemID = itemID
        self.expectedDeckID = expectedDeckID
    }
}

public extension ItemStore {
    /// Validates the whole selection and moves only assignments in one transaction.
    func moveItems(_ selection: [ItemMoveSelection], to deckID: UUID?) async throws -> Int {
        try await database.moveItems(selection, to: deckID)
    }
}
