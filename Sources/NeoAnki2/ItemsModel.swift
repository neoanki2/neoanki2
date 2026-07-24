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
    var addItemDeckID: UUID?

    let store: ItemStore

    init(store: ItemStore) {
        self.store = store
    }

    var itemType: ItemType? {
        guard let addItemTypeID else { return itemTypes.first }
        return itemTypes.first { $0.id == addItemTypeID } ?? itemTypes.first
    }

    func load(scope: StudyScope = .allDecks) async {
        isLoading = true
        errorMessage = nil
        do {
            itemTypes = try await store.listItemTypes()
            if addItemTypeID == nil {
                addItemTypeID = itemTypes.first?.id
            } else if !itemTypes.contains(where: { $0.id == addItemTypeID }) {
                addItemTypeID = itemTypes.first?.id
            }
            items = try await store.listItems(scope: scope.filter)
            dueCount = try await store.dueCount(scope: scope.filter)
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
    }

    func addItem(
        fieldSpans: [UUID: [Span]],
        fieldText: [UUID: String] = [:],
        deckID: UUID? = nil
    ) async -> Bool {
        errorMessage = nil
        guard let itemType else {
            errorMessage = "No item type is available."
            return false
        }

        let resolvedDeckID = deckID ?? addItemDeckID

        let fields = itemType.fields
            .filter(\.supportsTextInput)
            .map { field in
                let value: ContentValue = switch field.type {
                case .text, .richText:
                    field.contentValue(from: fieldSpans[field.id, default: []])
                case .number:
                    field.contentValue(from: fieldText[field.id, default: ""])
                case .audio, .image, .gif, .video:
                    .empty
                }

                return FieldValue(fieldID: field.id, value: value)
            }

        do {
            let item = Item(itemTypeID: itemType.id, fields: fields, deckID: resolvedDeckID)
            let saved = try await store.createItem(item)
            items.insert(saved, at: 0)
            dueCount = try await store.dueCount(scope: currentScopeFilter())
            return true
        } catch DatabaseError.requiredFieldEmpty(let field) {
            errorMessage = "\(field) is required."
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deleteItem(id: UUID, scope: StudyScope = .allDecks) async -> Bool {
        errorMessage = nil
        do {
            guard try await store.deleteItem(id: id) else { return false }
            items.removeAll { $0.id == id }
            dueCount = try await store.dueCount(scope: scope.filter)
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func moveItem(id: UUID, to deckID: UUID?, scope: StudyScope = .allDecks) async -> Bool {
        errorMessage = nil
        do {
            guard try await store.updateItemDeck(itemID: id, deckID: deckID) else { return false }
            await load(scope: scope)
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    private var cachedScope: StudyScope = .allDecks

    private func currentScopeFilter() -> DeckScope {
        cachedScope.filter
    }

    func setCachedScope(_ scope: StudyScope) {
        cachedScope = scope
    }
}
