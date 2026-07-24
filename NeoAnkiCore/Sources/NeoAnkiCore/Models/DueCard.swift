import Foundation

/// A card ready for study, with the item and template needed to render it.
public struct DueCard: Sendable, Identifiable, Equatable {
    public var id: UUID { card.id }
    public var card: Card
    public var item: Item
    public var itemType: ItemType
    public var template: Template

    public init(card: Card, item: Item, itemType: ItemType, template: Template) {
        self.card = card
        self.item = item
        self.itemType = itemType
        self.template = template
    }
}
