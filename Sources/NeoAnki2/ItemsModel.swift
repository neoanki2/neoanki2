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
    let mediaStore: MediaStore?

    init(store: ItemStore, mediaStore: MediaStore?) {
        self.store = store
        self.mediaStore = mediaStore
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
        fieldMedia: [UUID: MediaRef] = [:],
        fieldMediaAltText: [UUID: String] = [:],
        fieldClozeBlanks: [UUID: [ClozeSpan]] = [:],
        deckID: UUID? = nil
    ) async -> Bool {
        errorMessage = nil
        guard let itemType else {
            errorMessage = "No item type is available."
            return false
        }

        let resolvedDeckID = deckID ?? addItemDeckID

        do {
            var fields: [FieldValue] = []
            for field in itemType.fields {
                let value = try contentValue(
                    for: field,
                    fieldSpans: fieldSpans,
                    fieldText: fieldText,
                    fieldMedia: fieldMedia,
                    fieldMediaAltText: fieldMediaAltText,
                    fieldClozeBlanks: fieldClozeBlanks
                )
                if value.isEmpty, field.isRequired {
                    throw DatabaseError.requiredFieldEmpty(field.name)
                }
                if !value.isEmpty {
                    fields.append(FieldValue(fieldID: field.id, value: value))
                }
            }

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

    private func contentValue(
        for field: FieldDef,
        fieldSpans: [UUID: [Span]],
        fieldText: [UUID: String],
        fieldMedia: [UUID: MediaRef],
        fieldMediaAltText: [UUID: String],
        fieldClozeBlanks: [UUID: [ClozeSpan]]
    ) throws -> ContentValue {
        switch field.type {
        case .text, .richText:
            return field.contentValue(from: fieldSpans[field.id, default: []])
        case .number:
            return field.contentValue(from: fieldText[field.id, default: ""])
        case .audio, .image, .gif, .video:
            if var ref = fieldMedia[field.id] {
                let alt = fieldMediaAltText[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ref.altText = alt.isEmpty ? nil : alt
                return field.contentValue(from: ref)
            }
            return .empty
        case .cloze:
            let text = fieldText[field.id, default: ""]
            let blanks = fieldClozeBlanks[field.id, default: []]
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && blanks.isEmpty {
                return .empty
            }
            try ClozeValidation.validate(text: text, blanks: blanks)
            return field.contentValue(fromClozeText: text, blanks: blanks)
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
