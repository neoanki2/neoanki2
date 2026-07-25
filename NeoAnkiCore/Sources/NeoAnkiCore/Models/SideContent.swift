import Foundation

/// A resolved slot ready for native rendering, including presentation hints.
public struct ResolvedSlot: Sendable, Equatable {
    public var value: ContentValue
    public var presentation: Presentation

    public init(value: ContentValue, presentation: Presentation = Presentation()) {
        self.value = value
        self.presentation = presentation
    }
}

/// Resolves template sides into renderable content from an item's field values.
public enum SideContent {
    public static func resolvedSlots(for side: Side, from item: Item) -> [ResolvedSlot] {
        side.slots.compactMap { slot in
            guard let value = contentValue(for: slot.source, from: item), !value.isEmpty else {
                return nil
            }
            return ResolvedSlot(value: value, presentation: slot.presentation)
        }
    }

    public static func values(for side: Side, from item: Item) -> [ContentValue] {
        resolvedSlots(for: side, from: item).map(\.value)
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
