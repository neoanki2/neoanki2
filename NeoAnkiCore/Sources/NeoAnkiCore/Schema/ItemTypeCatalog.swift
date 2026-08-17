import Foundation

public struct IncludedItemTypeOwner: Sendable, Equatable {
    public let rootDeckID: UUID
    public let itemTypeID: UUID
    public let ordinal: Int

    public init(rootDeckID: UUID, itemTypeID: UUID, ordinal: Int) {
        self.rootDeckID = rootDeckID
        self.itemTypeID = itemTypeID
        self.ordinal = ordinal
    }
}

/// One explicitly declared item type in a deck's local authoring policy.
public struct DeckItemTypePolicyEntry: Sendable, Equatable {
    public let deckID: UUID
    public let itemTypeID: UUID
    public let ordinal: Int
    public let isDefault: Bool

    public init(deckID: UUID, itemTypeID: UUID, ordinal: Int, isDefault: Bool) {
        self.deckID = deckID
        self.itemTypeID = itemTypeID
        self.ordinal = ordinal
        self.isDefault = isDefault
    }
}

/// The nearest policy that applies to a selected deck.
public struct DeckItemTypePolicy: Sendable, Equatable {
    public let sourceDeckID: UUID
    public let itemTypes: [ItemType]
    public let defaultItemTypeID: UUID?

    public init(
        sourceDeckID: UUID,
        itemTypes: [ItemType],
        defaultItemTypeID: UUID?
    ) {
        self.sourceDeckID = sourceDeckID
        self.itemTypes = itemTypes
        self.defaultItemTypeID = defaultItemTypeID
    }

    public var automaticItemTypeID: UUID? {
        defaultItemTypeID ?? (itemTypes.count == 1 ? itemTypes[0].id : nil)
    }
}

/// Existing content that will share edits after a deck-provided item type is
/// adopted into the editable library catalog.
public struct ItemTypeEditingImpact: Sendable, Equatable {
    public let itemCount: Int
    public let deckCount: Int
    public let unassignedItemCount: Int

    public init(itemCount: Int, deckCount: Int, unassignedItemCount: Int) {
        self.itemCount = itemCount
        self.deckCount = deckCount
        self.unassignedItemCount = unassignedItemCount
    }
}

/// Populated fields whose stored values may no longer be usable after an item
/// type schema edit. Renames, reordering, and required-state changes are safe.
public struct ItemTypeSchemaChangeImpact: Sendable, Equatable {
    public let affectedItemCount: Int
    public let removedPopulatedFields: [String]
    public let typeChangedPopulatedFields: [String]

    public init(
        affectedItemCount: Int,
        removedPopulatedFields: [String],
        typeChangedPopulatedFields: [String]
    ) {
        self.affectedItemCount = affectedItemCount
        self.removedPopulatedFields = removedPopulatedFields
        self.typeChangedPopulatedFields = typeChangedPopulatedFields
    }

    public var requiresConfirmation: Bool {
        affectedItemCount > 0
            && (!removedPopulatedFields.isEmpty || !typeChangedPopulatedFields.isEmpty)
    }
}

/// Included-only definitions grouped beneath the imported root that owns them.
public struct IncludedItemTypeGroup: Sendable, Equatable, Identifiable {
    public let rootDeck: Deck
    public let deckPath: String
    public let itemTypes: [ItemType]

    public var id: UUID { rootDeck.id }

    public init(rootDeck: Deck, deckPath: String? = nil, itemTypes: [ItemType]) {
        self.rootDeck = rootDeck
        self.deckPath = deckPath ?? rootDeck.name
        self.itemTypes = itemTypes
    }
}

/// The user-facing item-type catalog. `itemTypes` are the unqualified,
/// reusable definitions; imported definitions are progressively disclosed.
public struct ItemTypeCatalog: Sendable, Equatable {
    public let itemTypes: [ItemType]
    public let includedWithDecks: [IncludedItemTypeGroup]
    public let corruptions: [QuarantinedItemTypeDefinition]

    public init(
        itemTypes: [ItemType],
        includedWithDecks: [IncludedItemTypeGroup],
        corruptions: [QuarantinedItemTypeDefinition]
    ) {
        self.itemTypes = itemTypes
        self.includedWithDecks = includedWithDecks
        self.corruptions = corruptions
    }

    public var allItemTypes: [ItemType] {
        let included = includedWithDecks.flatMap(\.itemTypes)
        var byID: [UUID: ItemType] = [:]
        for itemType in itemTypes + included {
            byID[itemType.id] = itemType
        }
        return byID.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public extension ItemType {
    /// Creates an independent editable copy while preserving schema behavior.
    func duplicated(name: String? = nil) -> ItemType {
        let fieldMap = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, UUID()) })
        let copiedFields = fields.map {
            FieldDef(
                id: fieldMap[$0.id]!,
                name: $0.name,
                type: $0.type,
                isRequired: $0.isRequired
            )
        }
        let copiedTemplates = templates.map { template in
            Template(
                id: UUID(),
                name: template.name,
                layout: template.layout,
                components: template.components.map { component in
                    TemplateComponent(
                        id: UUID(),
                        region: component.region,
                        purpose: component.purpose,
                        source: duplicatedSource(component.source, fieldMap: fieldMap),
                        presentation: component.presentation
                    )
                },
                interaction: template.interaction,
                skill: template.skill,
                generateWhen: template.generateWhen.map {
                    duplicatedCondition($0, fieldMap: fieldMap)
                }
            )
        }
        return ItemType(
            name: name ?? "\(self.name) Copy",
            fields: copiedFields,
            templates: copiedTemplates
        )
    }
}

private func duplicatedSource(_ source: SlotSource, fieldMap: [UUID: UUID]) -> SlotSource {
    switch source {
    case let .field(id): .field(fieldMap[id] ?? id)
    case let .literal(value): .literal(value)
    }
}

private func duplicatedSide(_ side: Side, fieldMap: [UUID: UUID]) -> Side {
    Side(slots: side.slots.map { slot in
        let source: SlotSource
        switch slot.source {
        case let .field(id):
            source = .field(fieldMap[id] ?? id)
        case let .literal(value):
            source = .literal(value)
        }
        return Slot(source: source, presentation: slot.presentation)
    })
}

private func duplicatedCondition(
    _ condition: SlotCondition,
    fieldMap: [UUID: UUID]
) -> SlotCondition {
    switch condition {
    case let .fieldNotEmpty(id):
        .fieldNotEmpty(fieldMap[id] ?? id)
    case let .fieldEmpty(id):
        .fieldEmpty(fieldMap[id] ?? id)
    case let .all(children):
        .all(children.map { duplicatedCondition($0, fieldMap: fieldMap) })
    case let .any(children):
        .any(children.map { duplicatedCondition($0, fieldMap: fieldMap) })
    }
}
