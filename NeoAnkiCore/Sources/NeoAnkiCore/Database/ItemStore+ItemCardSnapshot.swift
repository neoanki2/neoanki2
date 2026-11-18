import Foundation

public extension ItemStore {
    func itemCardSnapshot(id: UUID) async throws -> ItemCardSnapshot? {
        try await database.fetchItemCardSnapshot(id: id)
    }
}

extension SQLiteDatabase {
    func fetchItemCardSnapshot(id: UUID) throws -> ItemCardSnapshot? {
        try inReadTransaction {
            guard let persisted = try fetchItem(id: id),
                  let type = try fetchItemType(id: persisted.item.itemTypeID) else { return nil }
            return ItemCardSnapshot(item: persisted.item, itemType: type, cards: try fetchCards(for: id))
        }
    }
}
