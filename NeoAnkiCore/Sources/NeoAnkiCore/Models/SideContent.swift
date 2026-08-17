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

/// A semantic template component resolved for one item. Study surfaces use
/// these values to preserve region and reveal behavior without knowing how a
/// field is stored.
public struct ResolvedTemplateComponent: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var region: ComponentRegion
    public var purpose: ComponentPurpose
    public var value: ContentValue
    public var presentation: Presentation

    public init(
        id: UUID,
        region: ComponentRegion,
        purpose: ComponentPurpose,
        value: ContentValue,
        presentation: Presentation
    ) {
        self.id = id
        self.region = region
        self.purpose = purpose
        self.value = value
        self.presentation = presentation
    }
}

/// Resolves template sides into renderable content from an item's field values.
public enum SideContent {
    public static func resolvedComponents(
        for template: Template,
        from item: Item
    ) -> [ResolvedTemplateComponent] {
        template.components.compactMap { component in
            guard let value = contentValue(for: component.source, from: item), !value.isEmpty else {
                return nil
            }
            return ResolvedTemplateComponent(
                id: component.id,
                region: component.region,
                purpose: component.purpose,
                value: value,
                presentation: component.presentation
            )
        }
    }

    public static func values(
        for purpose: ComponentPurpose,
        in template: Template,
        from item: Item
    ) -> [ContentValue] {
        resolvedComponents(for: template, from: item)
            .filter { $0.purpose == purpose }
            .map(\.value)
    }

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

    public static func contentValue(for source: SlotSource, from item: Item) -> ContentValue? {
        switch source {
        case let .field(fieldID):
            return item.value(for: fieldID)
        case let .literal(string):
            return .text(string)
        }
    }
}
