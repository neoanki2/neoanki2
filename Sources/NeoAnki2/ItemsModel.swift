import Foundation
import NeoAnkiCore

@MainActor
@Observable
final class ItemsModel {
    private(set) var items: [SavedItemSummary] = []
    private(set) var itemType: ItemType?
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    private let store: ItemStore

    init(store: ItemStore) {
        self.store = store
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            itemType = try await store.defaultItemType()
            items = try await store.listItems()
        } catch {
            errorMessage = error.localizedDescription
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
            return true
        } catch DatabaseError.requiredFieldEmpty(let field) {
            errorMessage = "\(field) is required."
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
