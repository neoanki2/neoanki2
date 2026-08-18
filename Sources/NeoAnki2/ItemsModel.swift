import Foundation
import NeoAnkiApplication
import NeoAnkiCore

private enum ItemEditingError: Error {
    case missingItem
    case missingMediaDescription(String)
}

@MainActor
@Observable
final class ItemsModel {
    private(set) var items: [SavedItemSummary] = [] {
        didSet { refreshVisibleItems() }
    }
    private(set) var itemTypes: [ItemType] = []
    private(set) var normalItemTypes: [ItemType] = []
    private(set) var effectiveItemTypePolicy: DeckItemTypePolicy?
    /// The one scheduling snapshot for the selected scope. Everything the app
    /// says about what is due comes from here, so no two surfaces can disagree.
    private(set) var scopeSummary: ScopeSummary = .empty
    /// True only until the pane first has something to show. Later reloads
    /// revise what is on screen in place; a progress view where the numbers
    /// were is not an improvement on numbers a moment out of date.
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    private var hasLoaded = false
    private var itemTypesLoaded = false
    private var itemTypeWarning: String?
    private var loadedItemsScope: DeckScope?
    private var browseDataInvalidated = true
    var needsInitialLoad: Bool { !hasLoaded }
    var needsBrowseLoad: Bool {
        browseDataInvalidated || loadedItemsScope != cachedScope.filter
    }

    var addItemTypeID: ItemType.ID?
    var addItemDeckID: UUID?

    /// Browse-mode ordering, and the single ordering authority once items are
    /// loaded. Sorting stays local because a header click should not cost a
    /// query. The initial comparator mirrors `ItemSortOrder.createdAscending`,
    /// the order the store already returns.
    var tableSort: [KeyPathComparator<SavedItemSummary>] = [
        KeyPathComparator(\.createdAt, order: .forward),
    ] {
        didSet { items.sort(using: tableSort) }
    }

    var searchText = "" {
        didSet { scheduleVisibleItemsRefresh() }
    }

    var dueCount: Int { scopeSummary.dueNow }

    /// Items after the browse search, kept separate from `items` so a search
    /// never invalidates a selection or a lookup by identifier. Stored rather
    /// than computed: a table reads it several times per render pass, and each
    /// read would otherwise rescan every item.
    private(set) var visibleItems: [SavedItemSummary] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    private func refreshVisibleItems() {
        scheduleVisibleItemsRefresh()
    }

    /// Search input is published immediately by `searchText`; only the linear
    /// scan leaves the main actor. Generation checks make rapid typing
    /// deterministic even when an older scan finishes after a newer one.
    private func scheduleVisibleItemsRefresh() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            visibleItems = items
            searchTask = nil
            return
        }

        let snapshot = items
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var filtered: [SavedItemSummary] = []
            filtered.reserveCapacity(min(snapshot.count, 256))
            for (offset, item) in snapshot.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled {
                    return
                }
                if ItemBrowsing.matches(item, query: query) {
                    filtered.append(item)
                }
            }
            guard !Task.isCancelled else { return }
            await self?.publishVisibleItems(filtered, generation: generation)
        }
    }

    private func publishVisibleItems(_ filtered: [SavedItemSummary], generation: Int) {
        guard generation == searchGeneration else { return }
        visibleItems = filtered
        searchTask = nil
    }

    /// Lets tests and performance probes include asynchronous filtering without
    /// introducing a user-visible loading state.
    func waitForPendingSearch() async {
        await searchTask?.value
    }

    let library: any LibraryBrowsing & LibraryItemMutating & LibraryItemTypeManaging & LibraryStudyResponses
    let mediaStore: MediaStore?

    init(
        library: any LibraryBrowsing & LibraryItemMutating & LibraryItemTypeManaging & LibraryStudyResponses,
        mediaStore: MediaStore?
    ) {
        self.library = library
        self.mediaStore = mediaStore
    }

    var itemType: ItemType? {
        guard let addItemTypeID else { return nil }
        return itemTypes.first { $0.id == addItemTypeID }
    }

    var policyItemTypes: [ItemType] {
        effectiveItemTypePolicy?.itemTypes ?? []
    }

    var retainedItemType: ItemType? {
        guard let itemType,
              !policyItemTypes.contains(where: { $0.id == itemType.id }),
              !normalItemTypes.contains(where: { $0.id == itemType.id })
        else { return nil }
        return itemType
    }

    func isRecommendedItemType(_ itemTypeID: UUID) -> Bool {
        effectiveItemTypePolicy?.defaultItemTypeID == itemTypeID
    }

    /// `asOf` is passed in so the sidebar and the detail pane read the same
    /// instant. Letting each surface call `.now` is what made them disagree.
    func load(scope: StudyScope = .allDecks, asOf now: Date = .now) async {
        // `beginBrowseLoad` opts the home→Browse transition into the existing
        // loading state. Ordinary reloads keep populated rows visible.
        isLoading = isLoading || !hasLoaded
        errorMessage = itemTypeWarning
        updateCachedScope(scope)
        do {
            // Everything is read before anything is published, so a reload never
            // shows this scope's items beside another scope's counts.
            if !itemTypesLoaded {
                applyItemTypes(try await library.loadItemTypes())
            }
            let loadedItems = try await library.items(scope: scope.filter, sort: .createdAscending)
            let summary = try await library.scopeSummary(scope: scope.filter, asOf: now)

            items = loadedItems.sorted(using: tableSort)
            scopeSummary = summary
            hasLoaded = true
            loadedItemsScope = scope.filter
            browseDataInvalidated = false
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
    }

    /// Loads only the selected scope's home summary. Item types normally arrive
    /// from the startup snapshot; the fallback keeps direct model callers and
    /// snapshot failures behaviorally identical.
    func loadHome(scope: StudyScope = .allDecks, asOf now: Date = .now) async {
        isLoading = !hasLoaded
        errorMessage = itemTypeWarning
        updateCachedScope(scope)
        do {
            if !itemTypesLoaded {
                applyItemTypes(try await library.loadItemTypes())
            }
            scopeSummary = try await library.scopeSummary(scope: scope.filter, asOf: now)
            hasLoaded = true
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        isLoading = false
    }

    func beginBrowseLoad() {
        if needsBrowseLoad {
            isLoading = true
        }
    }

    func applyColdSnapshot(_ snapshot: ColdLibrarySnapshot, scope: StudyScope) {
        updateCachedScope(scope)
        applyItemTypes(snapshot.itemTypes)
        // The snapshot arrives in creation order. Honor the browse comparator
        // for the same reason `load` does: this path also runs when only the
        // sidebar is uninitialized, and a chosen column order has to survive it.
        items = snapshot.items.sorted(using: tableSort)
        scopeSummary = snapshot.selectedScopeSummary
        hasLoaded = true
        loadedItemsScope = scope.filter
        browseDataInvalidated = false
        isLoading = false
    }

    func applyColdHomeSnapshot(
        _ snapshot: ColdLibraryHomeSnapshot,
        scope: StudyScope
    ) {
        updateCachedScope(scope)
        applyItemTypes(snapshot.itemTypes)
        items = []
        loadedItemsScope = nil
        browseDataInvalidated = true
        scopeSummary = snapshot.selectedScopeSummary
        hasLoaded = true
        isLoading = false
    }

    private func applyItemTypes(_ result: ItemTypeLoadResult) {
        itemTypes = result.itemTypes
        normalItemTypes = result.itemTypes
        if addItemTypeID == nil
            || !itemTypes.contains(where: { $0.id == addItemTypeID }) {
            addItemTypeID = itemTypes.first?.id
        }
        if result.corruptions.isEmpty {
            itemTypeWarning = nil
        } else {
            let count = result.corruptions.count
            itemTypeWarning = count == 1
                ? "One damaged item type and its linked items were skipped. Open Item Types to archive the original and repair it."
                : "\(count) damaged item types and their linked items were skipped. Open Item Types to archive the originals and repair them."
        }
        errorMessage = itemTypeWarning
        itemTypesLoaded = true
    }

    func invalidateItemTypes() {
        itemTypesLoaded = false
    }

    /// Applies a committed native-import batch without re-reading every browse
    /// row already held by the model. Native imports are unassigned, so deck
    /// scopes only need their scheduling snapshot refreshed.
    func applyImportedItems(
        _ imported: [SavedItemSummary],
        scope: StudyScope,
        asOf now: Date = .now
    ) async {
        errorMessage = nil
        cachedScope = scope
        switch scope.filter {
        case .allDecks, .unassigned:
            let sortedImported = imported.sorted(using: tableSort)
            var updated = items
            if let last = updated.last,
               let first = sortedImported.first,
               compareUsingTableSort(last, first) == .orderedDescending {
                updated.append(contentsOf: sortedImported)
                updated.sort(using: tableSort)
            } else {
                // Native imports are normally newer than the loaded library,
                // so created-ascending order can append without sorting every
                // existing row again.
                updated.append(contentsOf: sortedImported)
            }
            items = updated
        case .deck:
            break
        }
        do {
            scopeSummary = try await library.scopeSummary(
                scope: currentScopeFilter(),
                asOf: now
            )
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
    }

    private func compareUsingTableSort(
        _ lhs: SavedItemSummary,
        _ rhs: SavedItemSummary
    ) -> ComparisonResult {
        for comparator in tableSort {
            let result = comparator.compare(lhs, rhs)
            if result != .orderedSame {
                return result
            }
        }
        return .orderedSame
    }

    /// Resolves authoring choices only after the destination deck is known.
    /// An ambiguous imported policy intentionally leaves the selection empty.
    func configureAddItem(for deckID: UUID?, resolveSelection: Bool = true) async {
        errorMessage = nil
        do {
            let catalog = try await library.loadItemTypeCatalog()
            itemTypes = catalog.allItemTypes
            normalItemTypes = catalog.itemTypes
            effectiveItemTypePolicy = if let deckID {
                try await library.effectiveItemTypePolicy(for: deckID)
            } else {
                nil
            }
            guard resolveSelection else { return }
            if let policy = effectiveItemTypePolicy {
                addItemTypeID = policy.automaticItemTypeID
            } else {
                addItemTypeID = normalItemTypes.first?.id
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
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
            let saved = try await library.createItem(item)
            items.append(saved)
            items.sort(using: tableSort)
            scopeSummary = try await library.scopeSummary(scope: currentScopeFilter())
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
            guard let stored = try await library.item(id: id) else {
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
            let saved = try await library.updateItem(item)
            if let index = items.firstIndex(where: { $0.id == saved.id }) {
                items[index] = saved
            }
            scopeSummary = try await library.scopeSummary(scope: currentScopeFilter())
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
            guard try await library.deleteItem(id: id) else { return false }
            items.removeAll { $0.id == id }
            scopeSummary = try await library.scopeSummary(scope: scope.filter)
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    func deleteAllUnassigned(scope: StudyScope = .unassigned) async -> Int {
        errorMessage = nil
        do {
            let deleted = try await library.deleteAllUnassignedItems()
            items.removeAll()
            scopeSummary = try await library.scopeSummary(scope: scope.filter)
            return deleted
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return 0
        }
    }

    func moveItem(
        id: UUID,
        to deckID: UUID?,
        scope: StudyScope = .allDecks,
        asOf now: Date = .now
    ) async -> Bool {
        errorMessage = nil
        do {
            guard try await library.moveItem(id: id, to: deckID) else { return false }
            await load(scope: scope, asOf: now)
            return true
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return false
        }
    }

    /// Moves a browse selection. Reports how many moved so a partial result is
    /// visible rather than silently rounded to success or failure. `asOf` is the
    /// caller's instant, so the reload agrees with the sidebar's.
    @discardableResult
    func moveItems(
        ids: Set<UUID>,
        to deckID: UUID?,
        scope: StudyScope = .allDecks,
        asOf now: Date = .now
    ) async -> Int {
        errorMessage = nil
        var moved = 0
        do {
            for id in orderedSelection(ids) {
                if try await library.moveItem(id: id, to: deckID) {
                    moved += 1
                }
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        await load(scope: scope, asOf: now)
        return moved
    }

    /// Acknowledges the selected rows at their cards' current lapse counts,
    /// then patches only those rows and the loaded scope summary.
    func markRepeatedLapsesOK(
        itemIDs: Set<UUID>,
        asOf now: Date = .now
    ) async -> Int? {
        guard !itemIDs.isEmpty else { return 0 }
        errorMessage = nil
        do {
            let acknowledgedCards = try await library.acknowledgeRepeatedLapses(
                itemIDs: itemIDs,
                asOf: now
            )
            await refreshSchedules(for: itemIDs, asOf: now)
            return acknowledgedCards
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return nil
        }
    }

    @discardableResult
    func deleteItems(
        ids: Set<UUID>,
        scope: StudyScope = .allDecks,
        asOf now: Date = .now
    ) async -> Int {
        errorMessage = nil
        var deleted = 0
        do {
            for id in orderedSelection(ids) {
                if try await library.deleteItem(id: id) {
                    deleted += 1
                }
            }
        } catch {
            errorMessage = UserFacingError.message(from: error)
        }
        await load(scope: scope, asOf: now)
        return deleted
    }

    func studyResponseCount(itemIDs: Set<UUID>) async -> Int {
        do {
            return try await library.studyResponseCount(itemIDs: itemIDs)
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return 0
        }
    }

    /// Acts in the order the user sees, so a failure part-way through leaves a
    /// comprehensible result.
    private func orderedSelection(_ ids: Set<UUID>) -> [UUID] {
        items.map(\.id).filter(ids.contains)
    }

    private var cachedScope: StudyScope = .allDecks

    private func currentScopeFilter() -> DeckScope {
        cachedScope.filter
    }

    func setCachedScope(_ scope: StudyScope) {
        updateCachedScope(scope)
    }

    private func updateCachedScope(_ scope: StudyScope) {
        if cachedScope.filter != scope.filter {
            browseDataInvalidated = true
        }
        cachedScope = scope
    }

    /// Re-reads the scheduling snapshot for the loaded scope without touching
    /// `isLoading` or the error banner. Cards come due while the app sits idle,
    /// so this is the path that keeps the headline honest between reloads.
    func refreshCounts(asOf now: Date = .now) async {
        guard hasLoaded,
              let summary = try? await library.scopeSummary(
                  scope: currentScopeFilter(),
                  asOf: now
              )
        else { return }

        if scopeSummary != summary {
            scopeSummary = summary
        }
    }

    /// Patches browse schedule columns for specific items without reloading the
    /// whole list. Used after study when titles and membership are unchanged.
    func refreshSchedules(for itemIDs: Set<UUID>, asOf now: Date = .now) async {
        guard hasLoaded, !itemIDs.isEmpty else { return }
        guard let schedules = try? await library.itemBrowseSchedules(itemIDs: Array(itemIDs)) else {
            return
        }

        var updated = items
        for index in updated.indices {
            let id = updated[index].id
            guard itemIDs.contains(id), let browseSchedule = schedules[id] else { continue }
            let existing = updated[index]
            updated[index] = SavedItemSummary(
                id: existing.id,
                itemTypeID: existing.itemTypeID,
                itemTypeName: existing.itemTypeName,
                title: existing.title,
                subtitle: existing.subtitle,
                cardCount: browseSchedule.cardCount,
                deckID: existing.deckID,
                createdAt: existing.createdAt,
                schedule: browseSchedule.schedule
            )
        }
        items = updated
        await refreshCounts(asOf: now)
    }
}
