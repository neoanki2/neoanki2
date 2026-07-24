import Foundation

/// Resolves template sides into renderable content from an item's field values.
public enum SideContent {
    public static func values(for side: Side, from item: Item) -> [ContentValue] {
        side.slots.compactMap { slot in
            let value = contentValue(for: slot.source, from: item)
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    private static func contentValue(for source: SlotSource, from item: Item) -> ContentValue? {
        switch source {
        case let .field(fieldID):
            return item.value(for: fieldID)
        case let .literal(string):
            return .text(string)
        }
    }
}
