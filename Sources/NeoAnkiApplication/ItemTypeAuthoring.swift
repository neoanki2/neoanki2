import Foundation
import NeoAnkiCore

/// Shared authoring operations. Each settings mutation resolves the current
/// policy instead of building a replacement from a view's potentially stale rows.
public struct ItemTypeAuthoring: Sendable {
    private let library: any LibraryBrowsing & LibraryItemTypeManaging

    public init(library: any LibraryBrowsing & LibraryItemTypeManaging) { self.library = library }
    public func catalog() async throws -> ItemTypeCatalog { try await library.loadItemTypeCatalog() }
    public func choices(for deckID: UUID?) async throws -> AuthoringItemTypes {
        try await library.authoringItemTypes(for: deckID)
    }
    public func attach(id: UUID, to deckID: UUID) async throws {
        try await library.attachItemType(id: id, to: deckID)
    }
    public func select(_ type: ItemType, for deckID: UUID?, independentCopy: Bool) async throws -> ItemType {
        if independentCopy {
            return try await library.createItemType(type.duplicated(), deckID: deckID, availableEverywhere: false)
        }
        if let deckID { try await attach(id: type.id, to: deckID) }
        return type
    }
    public func create(name: String, for deckID: UUID?) async throws -> ItemType {
        try await library.createItemType(BuiltInItemTypes.basic.duplicated(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)),
            deckID: deckID, availableEverywhere: deckID == nil)
    }
    public func setInheritance(_ inherits: Bool, for deckID: UUID) async throws {
        let current = try await choices(for: deckID)
        try await library.setDeckItemTypes(.init(deckID: deckID, inherits: inherits,
            itemTypeIDs: inherits ? [] : current.itemTypes.map(\.id),
            defaultItemTypeID: inherits ? nil : current.defaultItemTypeID))
    }
    public func setDefault(_ id: UUID, for deckID: UUID) async throws {
        let current = try await choices(for: deckID)
        try await library.setDeckItemTypes(.init(deckID: deckID,
            itemTypeIDs: current.itemTypes.map(\.id), defaultItemTypeID: id))
    }
    public func remove(_ id: UUID, from deckID: UUID) async throws {
        let current = try await choices(for: deckID)
        guard !current.usesSharedFallback else {
            throw DatabaseError.invalidItemType("Shared fallback types cannot be detached from this deck.")
        }
        try await library.setDeckItemTypes(.init(deckID: deckID,
            itemTypeIDs: current.itemTypes.map(\.id).filter { $0 != id },
            defaultItemTypeID: current.defaultItemTypeID == id ? nil : current.defaultItemTypeID))
    }
    public func makeAvailableEverywhere(_ id: UUID) async throws {
        try await library.setItemTypeAvailability(id: id, availableEverywhere: true)
    }
}
