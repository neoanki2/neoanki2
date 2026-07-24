import Foundation
import NeoAnkiCore

@MainActor
@Observable
final class ItemsModel {
    private(set) var items: [SavedItemSummary] = []
    private(set) var itemTypes: [ItemType] = []
    private(set) var dueCount = 0
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    var addItemTypeID: ItemType.ID?

    let store: ItemStore

    init(store: ItemStore) {
        self.store = store
    }

    var itemType: ItemType? {
        guard let addItemTypeID else { return itemTypes.first }
        return itemTypes.first { $0.id == addItemTypeID } ?? itemTypes.first
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            itemTypes = try await store.listItemTypes()
            if addItemTypeID == nil {
                addItemTypeID = itemTypes.first?.id
            } else if !itemTypes.contains(where: { $0.id == addItemTypeID }) {
                addItemTypeID = itemTypes.first?.id
            }
            items = try await store.listItems()
            dueCount = try await store.dueCount()
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
    }

    func addItem(fieldText: [UUID: String]) async -> Bool {
        errorMessage = nil
        guard let itemType else {
            errorMessage = "No item type is available."
            return false
        }

        let fields = itemType.fields
            .filter(\.supportsTextInput)
            .map { field in
                FieldValue(
                    fieldID: field.id,
                    value: field.contentValue(from: fieldText[field.id, default: ""])
                )
            }

        do {
            let item = Item(itemTypeID: itemType.id, fields: fields)
            let saved = try await store.createItem(item)
            items.insert(saved, at: 0)
            dueCount = try await store.dueCount()
            return true
        } catch DatabaseError.requiredFieldEmpty(let field) {
            errorMessage = "\(field) is required."
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deleteItem(id: UUID) async -> Bool {
        errorMessage = nil
        do {
            guard try await store.deleteItem(id: id) else { return false }
            items.removeAll { $0.id == id }
            dueCount = try await store.dueCount()
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }
}
