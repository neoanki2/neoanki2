import Foundation

/// Content and generated-card membership from a single database read snapshot.
/// Includes future-due cards so an editor reload never confuses eligibility with
/// liveness or accidentally loses a deferred learning repair.
public struct ItemCardSnapshot: Sendable, Equatable {
    public let item: Item
    public let itemType: ItemType
    public let cards: [Card]

    public init(item: Item, itemType: ItemType, cards: [Card]) {
        self.item = item
        self.itemType = itemType
        self.cards = cards
    }
}
