import Foundation
import NeoAnkiCore

public enum GeneratedDeckEditingError: Error, Sendable {
    case mixedItemTypes
    case missingItem
}

/// Shared loading and atomic commit for generated-source editors. Poem/prose
/// reconcilers retain their own source semantics; views never receive a repository.
public struct GeneratedDeckEditing: Sendable {
    public struct Record: Sendable {
        public let item: Item
        public let itemType: ItemType
        public let createdAt: Date
    }
    private let library: any LibraryBrowsing & LibraryCoordinatedItemEditing
    public init(library: any LibraryBrowsing & LibraryCoordinatedItemEditing) { self.library = library }

    public func load(deckID: UUID, itemTypeID: UUID) async throws -> [Record] {
        let summaries = try await library.items(scope: .deck(deckID, includeDescendants: false), sort: .createdAscending, search: "")
        guard summaries.allSatisfy({ $0.itemTypeID == itemTypeID }) else {
            throw GeneratedDeckEditingError.mixedItemTypes
        }
        var result: [Record] = []
        result.reserveCapacity(summaries.count)
        for summary in summaries {
            guard let record = try await library.item(id: summary.id) else {
                throw GeneratedDeckEditingError.missingItem
            }
            result.append(.init(item: record.item, itemType: record.itemType, createdAt: summary.createdAt))
        }
        return result
    }
    public func save(_ operations: [ItemBulkOperation], order: OrderedDeckItemReconciliation, asOf: Date) async throws {
        _ = try await library.reconcileOrderedDeckItems(operations, order: order, asOf: asOf)
    }
}
