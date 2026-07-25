import Foundation
import NeoAnkiCore

private enum ItemEditingError: Error {
    case missingItem
    case missingMediaDescription(String)
}

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
            let loadedItemTypes = try await store.loadItemTypes()
            itemTypes = loadedItemTypes.itemTypes
            if addItemTypeID == nil {
                addItemTypeID = itemTypes.first?.id
            } else if !itemTypes.contains(where: { $0.id == addItemTypeID }) {
                addItemTypeID = itemTypes.first?.id
            }
            items = try await store.listItems(scope: scope.filter)
            dueCount = try await store.dueCount(scope: scope.filter)
            if !loadedItemTypes.corruptions.isEmpty {
                let count = loadedItemTypes.corruptions.count
                errorMessage = count == 1
                    ? "One damaged item type and its linked items were skipped. Open Item Types to archive the original and repair it."
                    : "\(count) damaged item types and their linked items were skipped. Open Item Types to archive the originals and repair them."
            }
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
            let fields = try makeFields(
                for: itemType,
                fieldSpans: fieldSpans,
                fieldText: fieldText,
                fieldMedia: fieldMedia,
                fieldMediaAltText: fieldMediaAltText,
                fieldClozeBlanks: fieldClozeBlanks
            )

            let item = Item(itemTypeID: itemType.id, fields: fields, deckID: resolvedDeckID)
            let saved = try await store.createItem(item)
            items.insert(saved, at: 0)
            dueCount = try await store.dueCount(scope: currentScopeFilter())
            return true
        } catch DatabaseError.requiredFieldEmpty(let field) {
            errorMessage = "\(field) is required."
            return false
        } catch ItemEditingError.missingMediaDescription(let field) {
            errorMessage = "Add a description for \(field) so it works with VoiceOver."
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func updateItem(
        id: UUID,
        fieldSpans: [UUID: [Span]],
        fieldText: [UUID: String] = [:],
        fieldMedia: [UUID: MediaRef] = [:],
        fieldMediaAltText: [UUID: String] = [:],
        fieldClozeBlanks: [UUID: [ClozeSpan]] = [:]
    ) async -> Bool {
        errorMessage = nil

        do {
            guard let stored = try await store.fetchItem(id: id) else {
                throw ItemEditingError.missingItem
            }

            var fields = try makeFields(
                for: stored.itemType,
                fieldSpans: fieldSpans,
                fieldText: fieldText,
                fieldMedia: fieldMedia,
                fieldMediaAltText: fieldMediaAltText,
                fieldClozeBlanks: fieldClozeBlanks
            )
            preserveTextLanguages(in: &fields, from: stored.item)

            let item = Item(
                id: stored.item.id,
                itemTypeID: stored.item.itemTypeID,
                fields: fields,
                tags: stored.item.tags,
                deckID: stored.item.deckID
            )
            let saved = try await store.updateItem(item)
            if let index = items.firstIndex(where: { $0.id == saved.id }) {
                items[index] = saved
            }
            dueCount = try await store.dueCount(scope: currentScopeFilter())
            return true
        } catch DatabaseError.requiredFieldEmpty(let field) {
            errorMessage = "\(field) is required."
            return false
        } catch ItemEditingError.missingItem {
            errorMessage = "This item no longer exists."
            return false
        } catch ItemEditingError.missingMediaDescription(let field) {
            errorMessage = "Add a description for \(field) so it works with VoiceOver."
            return false
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    private func makeFields(
        for itemType: ItemType,
        fieldSpans: [UUID: [Span]],
        fieldText: [UUID: String],
        fieldMedia: [UUID: MediaRef],
        fieldMediaAltText: [UUID: String],
        fieldClozeBlanks: [UUID: [ClozeSpan]]
    ) throws -> [FieldValue] {
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
        return fields
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
                if [.image, .gif].contains(field.type), alt.isEmpty {
                    throw ItemEditingError.missingMediaDescription(field.name)
                }
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

    private func preserveTextLanguages(in fields: inout [FieldValue], from original: Item) {
        for index in fields.indices {
            guard case let .text(text, _) = fields[index].value,
                  case let .text(_, language)? = original.value(for: fields[index].fieldID) else {
                continue
            }
            fields[index].value = .text(text, lang: language)
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
