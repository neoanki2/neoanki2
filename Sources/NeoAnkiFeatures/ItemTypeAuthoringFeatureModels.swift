import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

@MainActor @Observable
public final class ItemTypeChooserFeatureModel {
    public let deckID: UUID?
    public private(set) var catalog: ItemTypeCatalog?
    public var query = ""
    public var name = ""
    public private(set) var error: String?
    public private(set) var isWorking = false
    private let authoring: ItemTypeAuthoring

    public init(authoring: ItemTypeAuthoring, deckID: UUID?) {
        self.authoring = authoring; self.deckID = deckID
    }
    public func matches(_ type: ItemType) -> Bool {
        query.isEmpty || type.name.localizedCaseInsensitiveContains(query)
    }
    public func load() async {
        do { catalog = try await authoring.catalog(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    public func choose(_ type: ItemType, independentCopy: Bool = false,
                       onSelected: (ItemType) async -> Void = { _ in }) async -> ItemType? {
        await perform(onSelected: onSelected) { try await authoring.select(type, for: deckID, independentCopy: independentCopy) }
    }
    public func create(onSelected: (ItemType) async -> Void = { _ in }) async -> ItemType? {
        await perform(onSelected: onSelected) { try await authoring.create(name: name, for: deckID) }
    }
    private func perform(onSelected: (ItemType) async -> Void, _ action: () async throws -> ItemType) async -> ItemType? {
        guard !isWorking else { return nil }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            let selected = try await action()
            await onSelected(selected)
            return selected
        }
        catch { self.error = error.localizedDescription; return nil }
    }
}

@MainActor @Observable
public final class DeckItemTypesFeatureModel {
    public let deckID: UUID
    public private(set) var choices: AuthoringItemTypes?
    public private(set) var sourceDeckName = ""
    public private(set) var affectedDeckCounts: [UUID: Int] = [:]
    public private(set) var hasParent = false
    public private(set) var error: String?
    public private(set) var isWorking = false
    public var inherits: Bool { choices?.sourceDeckID != deckID }
    private let authoring: ItemTypeAuthoring
    private let decks: any LibraryDeckManaging
    private let safeguards: (any LibraryItemTypeEditingSafeguarding)?
    private let onChanged: () async -> Void
    private var loadGeneration = 0

    public init(authoring: ItemTypeAuthoring, decks: any LibraryDeckManaging,
                safeguards: (any LibraryItemTypeEditingSafeguarding)? = nil,
                deckID: UUID, onChanged: @escaping () async -> Void = {}) {
        self.authoring = authoring; self.decks = decks; self.safeguards = safeguards
        self.deckID = deckID; self.onChanged = onChanged
    }
    public func makeChooser() -> ItemTypeChooserFeatureModel {
        ItemTypeChooserFeatureModel(authoring: authoring, deckID: deckID)
    }
    public func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let choices = try await authoring.choices(for: deckID)
            let name: String
            if let source = choices.sourceDeckID { name = try await decks.deck(id: source).name }
            else { name = "" }
            var counts: [UUID: Int] = [:]
            if let safeguards {
                for type in choices.itemTypes {
                    counts[type.id] = try await safeguards.itemTypeEditingImpact(id: type.id).deckPaths.count
                }
            }
            let hasParent = try await decks.deck(id: deckID).parentID != nil
            guard generation == loadGeneration else { return }
            self.choices = choices; sourceDeckName = name; affectedDeckCounts = counts
            self.hasParent = hasParent; error = nil
        } catch { if generation == loadGeneration { self.error = error.localizedDescription } }
    }
    public func setInheritance(_ value: Bool) async { await change { try await authoring.setInheritance(value, for: deckID) } }
    public func setDefault(_ id: UUID) async { await change { try await authoring.setDefault(id, for: deckID) } }
    public func remove(_ id: UUID) async { await change { try await authoring.remove(id, from: deckID) } }
    public func makeAvailableEverywhere(_ id: UUID) async { await change { try await authoring.makeAvailableEverywhere(id) } }
    public func didChooseType() async { await reload(); await onChanged() }
    private func change(_ action: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true; error = nil
        defer { isWorking = false }
        do { try await action(); await reload(); await onChanged() }
        catch { self.error = error.localizedDescription }
    }
}
