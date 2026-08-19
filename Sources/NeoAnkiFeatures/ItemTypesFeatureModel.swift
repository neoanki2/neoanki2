import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

public enum ItemTypesFeatureLoadState: Sendable, Equatable {
    case loading
    case ready
    case failed(UserFacingError)
}

public enum ItemTypesFeatureError: LocalizedError, Sendable, Equatable {
    case noSelection
    case itemTypeNotFound(UUID)
    case readOnlyItemType
    case includedItemTypeRequired
    case invalidDraft([ItemTypeStudioValidationIssue])
    case finalCardSetupRequired
    case staleSavePreparation
    case itemTypeHasItems(Int)
    case deletionFailed

    public var errorDescription: String? {
        switch self {
        case .noSelection:
            "Select an item type first."
        case .itemTypeNotFound:
            "The selected item type is no longer available."
        case .readOnlyItemType:
            "Deck-provided item types are read-only. Unlock or duplicate this definition to edit it."
        case .includedItemTypeRequired:
            "Select an item type provided by a deck."
        case .invalidDraft:
            "Fix the highlighted Item Type Studio errors before saving."
        case .finalCardSetupRequired:
            "An item type must have at least one Card setup."
        case .staleSavePreparation:
            "The draft changed after its save impact was prepared. Review the changes and save again."
        case let .itemTypeHasItems(count):
            "Remove the \(count) existing item\(count == 1 ? "" : "s") before deleting this item type."
        case .deletionFailed:
            "The item type was not deleted."
        }
    }
}

/// One field changed in place while retaining its stable identity.
public struct ItemTypeStudioFieldUpdate: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let previousName: String
    public let updatedName: String
    public let previousType: FieldType
    public let updatedType: FieldType
    public let previousRequired: Bool
    public let updatedRequired: Bool

    public init(previous: FieldDef, updated: FieldDef) {
        id = previous.id
        previousName = previous.name
        updatedName = updated.name
        previousType = previous.type
        updatedType = updated.type
        previousRequired = previous.isRequired
        updatedRequired = updated.isRequired
    }
}

/// A Card setup removal and the generated-card state that the atomic repository
/// update will retire. Persistent spoken responses are counted separately so a
/// shell can request explicit confirmation before committing the same update.
public struct ItemTypeStudioCardSetupRemoval: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    public var retiresGeneratedCards: Bool { true }
}

public struct ItemTypeStudioSaveImpact: Sendable, Equatable {
    public let removedFields: [FieldDef]
    public let changedFields: [ItemTypeStudioFieldUpdate]
    public let schemaChange: ItemTypeSchemaChangeImpact
    public let removedCardSetups: [ItemTypeStudioCardSetupRemoval]
    /// Presentation-safe count. Exact card identities stay in the private save
    /// authorization and are never exposed to Studio views.
    public let generatedCardRetirementCount: Int
    public let persistentSpokenResponseCount: Int

    public init(
        removedFields: [FieldDef],
        changedFields: [ItemTypeStudioFieldUpdate],
        schemaChange: ItemTypeSchemaChangeImpact,
        removedCardSetups: [ItemTypeStudioCardSetupRemoval],
        generatedCardRetirementCount: Int,
        persistentSpokenResponseCount: Int
    ) {
        self.removedFields = removedFields
        self.changedFields = changedFields
        self.schemaChange = schemaChange
        self.removedCardSetups = removedCardSetups
        self.generatedCardRetirementCount = generatedCardRetirementCount
        self.persistentSpokenResponseCount = persistentSpokenResponseCount
    }

    public var retiresGeneratedCards: Bool { generatedCardRetirementCount > 0 }

    /// Whether a platform should present the final Save action as destructive.
    /// Generated-card retirement can result from retained setup edits, so it
    /// must not be inferred only from removed Card setups.
    public var isDestructive: Bool {
        !removedFields.isEmpty
            || !removedCardSetups.isEmpty
            || generatedCardRetirementCount > 0
            || persistentSpokenResponseCount > 0
            || schemaChange.requiresConfirmation
    }

    public var requiresConfirmation: Bool {
        schemaChange.requiresConfirmation
            || !removedCardSetups.isEmpty
            || generatedCardRetirementCount > 0
            || persistentSpokenResponseCount > 0
    }

    public static let none = ItemTypeStudioSaveImpact(
        removedFields: [],
        changedFields: [],
        schemaChange: ItemTypeSchemaChangeImpact(
            affectedItemCount: 0,
            removedPopulatedFields: [],
            typeChangedPopulatedFields: []
        ),
        removedCardSetups: [],
        generatedCardRetirementCount: 0,
        persistentSpokenResponseCount: 0
    )
}

/// Immutable result of validation and impact calculation. `commitSave` accepts
/// only a preparation matching the active draft, preventing a stale confirmation
/// from authorizing later changes.
public struct ItemTypeStudioSavePreparation: Sendable, Equatable {
    public let candidate: ItemType
    public let impact: ItemTypeStudioSaveImpact

    fileprivate let originalSnapshot: ItemType?
    fileprivate let updateAuthorization: ItemTypeUpdateAuthorization?

    fileprivate init(
        candidate: ItemType,
        originalSnapshot: ItemType?,
        impact: ItemTypeStudioSaveImpact,
        updateAuthorization: ItemTypeUpdateAuthorization?
    ) {
        self.candidate = candidate
        self.originalSnapshot = originalSnapshot
        self.impact = impact
        self.updateAuthorization = updateAuthorization
    }

    public var createsItemType: Bool { originalSnapshot == nil }
}

/// Shared Item Type Studio workflow for macOS and iOS. This type owns all
/// item-type repository mutations so fields and Card setups are persisted as
/// one complete `ItemType` update instead of independent template mutations.
@MainActor @Observable
public final class ItemTypesFeatureModel {
    public private(set) var itemTypes: [ItemType] = []
    public private(set) var includedItemTypeGroups: [IncludedItemTypeGroup] = []
    public private(set) var corruptedDefinitions: [QuarantinedItemTypeDefinition] = []
    public private(set) var loadState: ItemTypesFeatureLoadState = .loading
    public private(set) var selectedItemTypeID: UUID?
    public var studioDraft: ItemTypeStudioDraft?

    private let library: any LibraryBrowsing
        & LibraryItemTypeManaging
        & LibraryItemTypeEditingSafeguarding
        & LibraryItemTypeStudioSaving
    private let errorMapper: any UserFacingErrorMapping

    public init(
        library: any LibraryBrowsing
            & LibraryItemTypeManaging
            & LibraryItemTypeEditingSafeguarding
            & LibraryItemTypeStudioSaving,
        errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper()
    ) {
        self.library = library
        self.errorMapper = errorMapper
    }

    public var selectedItemType: ItemType? {
        guard let selectedItemTypeID else { return nil }
        return itemTypes.first { $0.id == selectedItemTypeID }
            ?? includedItemTypeGroups.lazy
                .flatMap(\.itemTypes)
                .first { $0.id == selectedItemTypeID }
    }

    public var selectedIncludedGroup: IncludedItemTypeGroup? {
        guard let selectedItemTypeID else { return nil }
        return includedItemTypeGroups.first { group in
            group.itemTypes.contains { $0.id == selectedItemTypeID }
        }
    }

    public var isSelectedItemTypeReadOnly: Bool { selectedIncludedGroup != nil }

    public func load() async {
        loadState = .loading
        do {
            try await reloadCatalog(selecting: selectedItemTypeID)
            loadState = .ready
        } catch {
            loadState = .failed(errorMapper.map(error))
        }
    }

    public func selectItemType(id: UUID?) {
        guard let id else {
            selectedItemTypeID = nil
            return
        }
        guard itemType(id: id) != nil else { return }
        selectedItemTypeID = id
    }

    public func beginCreatingItemType(id: UUID = UUID()) {
        selectedItemTypeID = nil
        studioDraft = .new(id: id)
    }

    @discardableResult
    public func beginEditingSelectedItemType() -> Bool {
        guard let selectedItemType else { return false }
        studioDraft = ItemTypeStudioDraft(itemType: selectedItemType)
        return true
    }

    public func discardStudioDraft() {
        studioDraft = nil
    }

    /// Validates the entire candidate and obtains every persistence impact
    /// before any repository mutation occurs.
    public func prepareSave() async throws -> ItemTypeStudioSavePreparation {
        guard let draft = studioDraft else { throw ItemTypesFeatureError.noSelection }
        guard draft.cardSetups.isEmpty == false else {
            throw ItemTypesFeatureError.finalCardSetupRequired
        }
        guard draft.validationIssues.isEmpty else {
            throw ItemTypesFeatureError.invalidDraft(draft.validationIssues)
        }

        let candidate = try draft.candidateItemType()
        guard candidate.templates.isEmpty == false else {
            throw ItemTypesFeatureError.finalCardSetupRequired
        }

        guard let original = draft.originalSnapshot else {
            return ItemTypeStudioSavePreparation(
                candidate: candidate,
                originalSnapshot: nil,
                impact: .none,
                updateAuthorization: nil
            )
        }
        guard isReadOnlyItemType(id: original.id) == false else {
            throw ItemTypesFeatureError.readOnlyItemType
        }
        guard itemTypes.contains(where: { $0.id == original.id }) else {
            throw ItemTypesFeatureError.itemTypeNotFound(original.id)
        }

        let authorization = try await library.prepareItemTypeUpdateAuthorization(
            from: original,
            to: candidate
        )
        let updatedFields = Dictionary(uniqueKeysWithValues: candidate.fields.map { ($0.id, $0) })
        let removedFields = original.fields.filter { updatedFields[$0.id] == nil }
        let changedFields = original.fields.compactMap { previous -> ItemTypeStudioFieldUpdate? in
            guard let updated = updatedFields[previous.id], updated != previous else { return nil }
            return ItemTypeStudioFieldUpdate(previous: previous, updated: updated)
        }
        let candidateSetupIDs = Set(candidate.templates.map(\.id))
        let removedCardSetups: [ItemTypeStudioCardSetupRemoval] = original.templates.compactMap { template in
            guard candidateSetupIDs.contains(template.id) == false else { return nil }
            return ItemTypeStudioCardSetupRemoval(id: template.id, name: template.name)
        }
        return ItemTypeStudioSavePreparation(
            candidate: candidate,
            originalSnapshot: original,
            impact: ItemTypeStudioSaveImpact(
                removedFields: removedFields,
                changedFields: changedFields,
                schemaChange: authorization.schemaChangeImpact,
                removedCardSetups: removedCardSetups,
                generatedCardRetirementCount: authorization.expectedGeneratedCardRetirementCount,
                persistentSpokenResponseCount: authorization.expectedStudyResponseDeletionCount
            ),
            updateAuthorization: authorization
        )
    }

    /// Persists one complete candidate with exactly one create/update call.
    /// Core performs generated-card reconciliation transactionally inside the
    /// update; this feature then reloads the catalog and keeps the saved type selected.
    @discardableResult
    public func commitSave(
        _ preparation: ItemTypeStudioSavePreparation,
        asOf now: Date = .now
    ) async throws -> ItemType {
        guard let draft = studioDraft,
              draft.originalSnapshot == preparation.originalSnapshot,
              try draft.candidateItemType() == preparation.candidate
        else {
            throw ItemTypesFeatureError.staleSavePreparation
        }
        let committedDraft = draft

        let saved: ItemType
        if preparation.createsItemType {
            saved = try await library.createItemType(preparation.candidate)
        } else {
            guard isReadOnlyItemType(id: preparation.candidate.id) == false else {
                throw ItemTypesFeatureError.readOnlyItemType
            }
            guard let authorization = preparation.updateAuthorization else {
                throw ItemTypesFeatureError.staleSavePreparation
            }
            do {
                saved = try await library.updateItemType(
                    preparation.candidate,
                    authorization: authorization,
                    asOf: now
                )
            } catch let error as ItemTypeUpdateError {
                if case .staleDefinition = error {
                    try? await reloadCatalog(selecting: preparation.candidate.id)
                    if preparation.candidate == preparation.originalSnapshot,
                       studioDraft == committedDraft,
                       let refreshed = itemType(id: preparation.candidate.id) {
                        studioDraft = ItemTypeStudioDraft(itemType: refreshed)
                    }
                }
                throw error
            }
        }

        try await reloadCatalog(selecting: saved.id)
        if studioDraft == committedDraft {
            studioDraft = ItemTypeStudioDraft(itemType: saved)
        } else if var newerDraft = studioDraft,
                  newerDraft.id == committedDraft.id,
                  newerDraft.originalSnapshot == committedDraft.originalSnapshot {
            newerDraft.rebaseOriginalSnapshot(
                to: saved,
                discardingTransientStateFrom: committedDraft
            )
            studioDraft = newerDraft
        }
        loadState = .ready
        return saved
    }

    public func editingImpactForSelectedIncludedItemType() async throws -> ItemTypeEditingImpact {
        guard let selectedItemTypeID else { throw ItemTypesFeatureError.noSelection }
        return try await editingImpactForIncludedItemType(id: selectedItemTypeID)
    }

    /// Prepares the exact deck-provided definition named by the initiating UI
    /// action, independent of later navigator selection changes.
    public func editingImpactForIncludedItemType(id: UUID) async throws -> ItemTypeEditingImpact {
        guard itemType(id: id) != nil else { throw ItemTypesFeatureError.itemTypeNotFound(id) }
        guard isReadOnlyItemType(id: id) else {
            throw ItemTypesFeatureError.includedItemTypeRequired
        }
        return try await library.itemTypeEditingImpact(id: id)
    }

    @discardableResult
    public func unlockSelectedItemType() async throws -> ItemType {
        guard let selectedItemTypeID else { throw ItemTypesFeatureError.noSelection }
        return try await unlockItemType(id: selectedItemTypeID)
    }

    /// Unlocks the exact definition authorized by a shell confirmation. The
    /// catalog is rechecked at execution time and reload selects that identity.
    @discardableResult
    public func unlockItemType(id: UUID) async throws -> ItemType {
        guard itemType(id: id) != nil else { throw ItemTypesFeatureError.itemTypeNotFound(id) }
        guard isReadOnlyItemType(id: id) else {
            throw ItemTypesFeatureError.includedItemTypeRequired
        }
        let unlocked = try await library.unlockItemType(id: id)
        try await reloadCatalog(selecting: unlocked.id)
        loadState = .ready
        return unlocked
    }

    @discardableResult
    public func duplicateSelectedIncludedItemType(name: String) async throws -> ItemType {
        guard let selectedItemTypeID else { throw ItemTypesFeatureError.noSelection }
        guard isReadOnlyItemType(id: selectedItemTypeID) else {
            throw ItemTypesFeatureError.includedItemTypeRequired
        }
        let duplicate = try await library.duplicateItemType(id: selectedItemTypeID, name: name)
        try await reloadCatalog(selecting: duplicate.id)
        loadState = .ready
        return duplicate
    }

    @discardableResult
    public func repairDefinition(
        _ corruption: QuarantinedItemTypeDefinition,
        asOf now: Date = .now
    ) async throws -> ItemType {
        guard let id = corruption.repairableID else {
            throw DatabaseError.invalidItemType(
                "This damaged item type has an invalid identifier and needs manual recovery."
            )
        }
        let repaired = try await library.repairItemTypeDefinition(id: id, asOf: now)
        try await reloadCatalog(selecting: repaired.id)
        loadState = .ready
        return repaired
    }

    public func selectedItemTypeDeletionImpact() async throws -> Int {
        guard let selectedItemTypeID else { throw ItemTypesFeatureError.noSelection }
        guard isReadOnlyItemType(id: selectedItemTypeID) == false else {
            throw ItemTypesFeatureError.readOnlyItemType
        }
        return try await library.countItems(itemTypeID: selectedItemTypeID)
    }

    public func deleteSelectedItemType() async throws {
        guard let selectedItemTypeID else { throw ItemTypesFeatureError.noSelection }
        guard isReadOnlyItemType(id: selectedItemTypeID) == false else {
            throw ItemTypesFeatureError.readOnlyItemType
        }
        let itemCount = try await library.countItems(itemTypeID: selectedItemTypeID)
        guard itemCount == 0 else { throw ItemTypesFeatureError.itemTypeHasItems(itemCount) }
        guard try await library.deleteItemType(id: selectedItemTypeID) else {
            throw ItemTypesFeatureError.deletionFailed
        }
        studioDraft = nil
        try await reloadCatalog(selecting: nil)
        loadState = .ready
    }

    private func itemType(id: UUID) -> ItemType? {
        itemTypes.first { $0.id == id }
            ?? includedItemTypeGroups.lazy.flatMap(\.itemTypes).first { $0.id == id }
    }

    private func isReadOnlyItemType(id: UUID) -> Bool {
        includedItemTypeGroups.contains { group in
            group.itemTypes.contains { $0.id == id }
        }
    }

    private func reloadCatalog(selecting preferredID: UUID?) async throws {
        let catalog = try await library.loadItemTypeCatalog()
        itemTypes = catalog.itemTypes
        includedItemTypeGroups = catalog.includedWithDecks
        corruptedDefinitions = catalog.corruptions

        if let preferredID, itemType(id: preferredID) != nil {
            selectedItemTypeID = preferredID
        } else if let current = selectedItemTypeID, itemType(id: current) != nil {
            selectedItemTypeID = current
        } else {
            selectedItemTypeID = itemTypes.first?.id
                ?? includedItemTypeGroups.lazy.flatMap(\.itemTypes).first?.id
        }
    }
}
