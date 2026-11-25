import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures

private enum ItemEditingError: Error {
    case missingItem
}

@MainActor
@Observable
final class ItemsModel {
    private(set) var items: [SavedItemSummary] = [] {
        didSet { refreshVisibleItems() }
    }
    private(set) var itemTypes: [ItemType] = []
    private var authoringLoadGeneration = 0
    private var loadGeneration: UInt64 = 0
    private let reads: NativeLibraryReadCoordinator
    @ObservationIgnored private var libraryChangesTask: Task<Void, Never>?
    private(set) var lastCommandReceipt: NativeCommandReceipt?
    private(set) var normalItemTypes: [ItemType] = []
    private(set) var effectiveItemTypePolicy: DeckItemTypePolicy?
    /// The one scheduling snapshot for the selected scope. Everything the app
    /// says about what is due comes from here, so no two surfaces can disagree.
    private(set) var scopeSummary: ScopeSummary = .empty
    private var loadedSummaryScope: DeckScope?
    private(set) var maturityUnavailable = false
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

    func scopeSummary(for scope: DeckScope) -> ScopeSummary? {
        guard loadedSummaryScope == scope else { return nil }
        return scopeSummary
    }

    private func applyScopeSummary(_ summary: ScopeSummary, for scope: DeckScope) {
        if scopeSummary != summary { scopeSummary = summary }
        if loadedSummaryScope != scope { loadedSummaryScope = scope }
    }

    /// Items after the browse search, kept separate from `items` so a search
    /// never invalidates a selection or a lookup by identifier. Stored rather
    /// than computed: a table reads it several times per render pass, and each
    /// read would otherwise rescan every item.
    private(set) var visibleItems: [SavedItemSummary] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
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

    /// Waits for the current search to settle, including a replacement scan
    /// scheduled by a library refresh while the first scan was running.
    func waitForPendingSearch() async {
        while let searchTask {
            await searchTask.value
        }
    }

    func hasStandaloneCourseLesson(in scope: DeckScope) async -> Bool {
        (try? await (library as? any LibraryCourseStudying)?.hasStandaloneCourseLesson(in: scope)) == true
    }

    private let library: any LibraryBrowsing & LibraryItemMutating & LibraryItemTypeManaging
        & LibraryStudyResponses & LibraryCoordinatedItemEditing
    let mediaStore: MediaStore?

    init(
        library: any LibraryBrowsing & LibraryItemMutating & LibraryItemTypeManaging
            & LibraryStudyResponses & LibraryCoordinatedItemEditing,
        mediaStore: MediaStore?,
        reads: NativeLibraryReadCoordinator? = nil
    ) {
        self.library = library
        self.mediaStore = mediaStore
        self.reads = reads ?? NativeLibraryReadCoordinator(library: library)
        libraryChangesTask = Task { [weak self, reads = self.reads] in
            let changes = await reads.invalidations()
            for await _ in changes {
                guard !Task.isCancelled, let self else { return }
                browseDataInvalidated = true
                guard hasLoaded else { continue }
                invalidateItemTypes()
                scheduleCommittedRefresh(browse: loadedItemsScope != nil)
            }
        }
    }

    deinit { libraryChangesTask?.cancel(); searchTask?.cancel() }

    var generatedDeckEditing: GeneratedDeckEditing { .init(library: library) }
    func makeTypeChooser(deckID: UUID?) -> ItemTypeChooserFeatureModel {
        .init(authoring: .init(library: library), deckID: deckID)
    }
    func authoringChoices(for deckID: UUID?) async throws -> AuthoringItemTypes {
        try await ItemTypeAuthoring(library: library).choices(for: deckID)
    }
    func attachType(id: UUID, to deckID: UUID) async throws {
        try await ItemTypeAuthoring(library: library).attach(id: id, to: deckID)
    }
    func item(id: UUID) async throws -> (item: Item, itemType: ItemType)? { try await library.item(id: id) }
    func cardMaturityDetails(itemID: UUID) async throws -> [CardMaturityDetail] {
        try await library.cardMaturityDetails(itemID: itemID)
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
        await load(scope: scope, asOf: now, browse: true)
    }

    func loadHome(scope: StudyScope = .allDecks, asOf now: Date = .now) async {
        await load(scope: scope, asOf: now, browse: false)
    }

    private func load(scope: StudyScope, asOf now: Date, browse: Bool) async {
        updateCachedScope(scope)
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = isLoading || !hasLoaded
        errorMessage = itemTypeWarning
        do {
            var demand: Set<NativeLibraryReadDemand> = [.summary]
            if browse { demand.insert(.browse) }
            if !itemTypesLoaded { demand.insert(.catalog) }
            let snapshot = try await reads.load(scope: scope.filter, demand: demand, asOf: now)
            guard generation == loadGeneration, cachedScope.filter == scope.filter else { return }
            if let catalog = snapshot.catalog {
                applyItemTypes(ItemTypeLoadResult(itemTypes: catalog.allItemTypes, corruptions: catalog.corruptions))
            }
            if let rows = snapshot.items {
                items = rows.sorted(using: tableSort)
                loadedItemsScope = scope.filter
                browseDataInvalidated = false
            }
            if let summary = snapshot.summary { applyScopeSummary(summary, for: scope.filter) }
            maturityUnavailable = snapshot.maturityIssue != nil
            errorMessage = snapshot.maturityIssue.map { "Maturity is unavailable. " + $0 } ?? itemTypeWarning
            hasLoaded = true
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = UserFacingError.message(from: error)
        }
        if generation == loadGeneration { isLoading = false }
    }

    func beginBrowseLoad() {
        if needsBrowseLoad {
            isLoading = true
        }
    }

    func applyColdSnapshot(_ snapshot: ColdLibrarySnapshot, scope: StudyScope) {
        loadGeneration &+= 1
        updateCachedScope(scope)
        applyItemTypes(snapshot.itemTypes)
        // The snapshot arrives in creation order. Honor the browse comparator
        // for the same reason `load` does: this path also runs when only the
        // sidebar is uninitialized, and a chosen column order has to survive it.
        items = snapshot.items.sorted(using: tableSort)
        applyScopeSummary(snapshot.selectedScopeSummary, for: scope.filter)
        hasLoaded = true
        loadedItemsScope = scope.filter
        browseDataInvalidated = false
        isLoading = false
    }

    func applyColdHomeSnapshot(
        _ snapshot: ColdLibraryHomeSnapshot,
        scope: StudyScope
    ) {
        loadGeneration &+= 1
        updateCachedScope(scope)
        applyItemTypes(snapshot.itemTypes)
        items = []
        loadedItemsScope = nil
        browseDataInvalidated = true
        applyScopeSummary(snapshot.selectedScopeSummary, for: scope.filter)
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

    /// Applies committed rows by identity. A deck browser resolves descendant
    /// membership through the shared read coordinator.
    func applyImportedItems(
        _ imported: [SavedItemSummary],
        scope: StudyScope,
        asOf now: Date = .now
    ) async {
        loadGeneration &+= 1
        errorMessage = nil
        cachedScope = scope
        let importedIDs = Set(imported.map(\.id))
        items.removeAll { importedIDs.contains($0.id) }
        switch scope.filter {
        case .allDecks, .unassigned:
            let visibleImported = scope.filter == .unassigned ? imported.filter { $0.deckID == nil } : imported
            let sortedImported = visibleImported.sorted(using: tableSort)
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
            await load(scope: scope, asOf: now)
        }
        guard scope.filter == currentScopeFilter() else { return }
        let generation = loadGeneration
        do {
            let summary = try await library.scopeSummary(scope: scope.filter, asOf: now)
            guard generation == loadGeneration else { return }
            applyScopeSummary(summary, for: scope.filter)
        } catch {
            guard generation == loadGeneration else { return }
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
        authoringLoadGeneration += 1
        let generation = authoringLoadGeneration
        errorMessage = nil
        do {
            let catalog = try await library.loadItemTypeCatalog()
            let choices = try await library.authoringItemTypes(for: deckID)
            let libraryID = try await library.libraryID()
            guard generation == authoringLoadGeneration else { return }
            itemTypes = catalog.allItemTypes
            normalItemTypes = []
            effectiveItemTypePolicy = DeckItemTypePolicy(sourceDeckID: choices.sourceDeckID ?? deckID ?? libraryID,
                itemTypes: choices.itemTypes, defaultItemTypeID: choices.defaultItemTypeID)
            guard resolveSelection else { return }
            let key = "authoring.type.\(libraryID).\(deckID?.uuidString ?? "unassigned")"
            let remembered = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
            addItemTypeID = remembered.flatMap { id in choices.itemTypes.contains { $0.id == id } ? id : nil } ?? choices.automaticItemTypeID
        } catch {
            guard generation == authoringLoadGeneration else { return }
            errorMessage = UserFacingError.message(from: error)
        }
    }

    func addItem(
        fieldSpans: [UUID: [Span]],
        fieldText: [UUID: String] = [:],
        fieldMedia: [UUID: MediaRef] = [:],
        fieldMediaAltText: [UUID: String] = [:],
        fieldClozeBlanks: [UUID: [ClozeSpan]] = [:],
        fieldOcclusions: [UUID: ImageOcclusionContent] = [:],
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
                fieldClozeBlanks: fieldClozeBlanks,
                fieldOcclusions: fieldOcclusions
            )

            let item = Item(itemTypeID: itemType.id, fields: fields, deckID: resolvedDeckID)
            let rememberedLibraryID = try? await library.libraryID()
            let selectedScope = currentScopeFilter()
            let destinationIsVisible = await scopeContains(deckID: resolvedDeckID, scope: selectedScope)
            let outcome = try await command("create-item") { try await library.createItem(item) }
            guard let saved = outcome.value else { scheduleCommittedRefresh(browse: true); return true }
            if let libraryID = rememberedLibraryID {
                UserDefaults.standard.set(itemType.id.uuidString, forKey: "authoring.type.\(libraryID).\(resolvedDeckID?.uuidString ?? "unassigned")")
            }
            if selectedScope == currentScopeFilter(), destinationIsVisible == true {
                items.removeAll { $0.id == saved.id }
                items.append(saved)
                items.sort(using: tableSort)
            }
            scheduleCommittedRefresh(browse: selectedScope != currentScopeFilter() || destinationIsVisible == nil)
            return true
        } catch DatabaseError.requiredFieldEmpty(let field) {
            errorMessage = "\(field) is required."
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
        fieldClozeBlanks: [UUID: [ClozeSpan]] = [:],
        fieldOcclusions: [UUID: ImageOcclusionContent] = [:]
    ) async -> Bool {
        errorMessage = nil

        do {
            guard let stored = try await library.item(id: id) else {
                throw ItemEditingError.missingItem
            }

            var draft = ItemEditorDraft(item: stored.item, itemType: stored.itemType)
            draft.snapshot = ItemEditorSnapshot(fieldSpans: fieldSpans, fieldText: fieldText,
                fieldMedia: fieldMedia, fieldMediaAltText: fieldMediaAltText,
                fieldClozeBlanks: fieldClozeBlanks, fieldOcclusions: fieldOcclusions)
            let item = try draft.item()
            let updated = ContextDerivedContent.invalidatingSpeech(in: item, original: stored.item, type: stored.itemType)
            let outcome = try await command("update-item") { try await library.updateItem(updated) }
            guard let saved = outcome.value else { scheduleCommittedRefresh(browse: true); return true }
            if let index = items.firstIndex(where: { $0.id == saved.id }) {
                items[index] = saved
            }
            scheduleCommittedRefresh()
            return true
        } catch DatabaseError.requiredFieldEmpty(let field) {
            errorMessage = "\(field) is required."
            return false
        } catch ItemEditingError.missingItem {
            errorMessage = "This item no longer exists."
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
        fieldClozeBlanks: [UUID: [ClozeSpan]],
        fieldOcclusions: [UUID: ImageOcclusionContent]
    ) throws -> [FieldValue] {
        return try ItemEditorState.fields(from: ItemEditorSnapshot(
            fieldSpans: fieldSpans, fieldText: fieldText, fieldMedia: fieldMedia,
            fieldMediaAltText: fieldMediaAltText, fieldClozeBlanks: fieldClozeBlanks,
            fieldOcclusions: fieldOcclusions), itemType: itemType)
    }

    func deleteItem(id: UUID, scope: StudyScope = .allDecks) async -> Bool {
        await deleteItems(ids: [id], scope: scope) == 1
    }

    func deleteAllUnassigned(scope: StudyScope = .unassigned) async -> Int {
        errorMessage = nil
        do {
            let outcome = try await command("delete-unassigned") { try await library.deleteAllUnassignedItems() }
            let deleted = outcome.value ?? outcome.affectedCount ?? 0
            items.removeAll { $0.deckID == nil }
            scheduleCommittedRefresh()
            return deleted
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return 0
        }
    }

    func moveItem(id: UUID, to deckID: UUID?, scope: StudyScope = .allDecks, asOf now: Date = .now) async -> Bool {
        await moveItems(ids: [id], to: deckID, scope: scope, asOf: now) == 1
    }

    /// Selection validation and all assignments commit together.
    @discardableResult
    func moveItems(ids: Set<UUID>, to deckID: UUID?, scope: StudyScope = .allDecks,
        asOf now: Date = .now) async -> Int {
        errorMessage = nil
        do {
            let selection = try NativeLibraryCommands.selection(ids, rows: items)
            let selectedScope = currentScopeFilter()
            let destinationIsVisible = await scopeContains(deckID: deckID, scope: selectedScope)
            let outcome = try await command("move", count: ids.count) {
                try await NativeLibraryCommands.move(on: library, selection: selection, to: deckID)
            }
            // Publish the committed selection before any optional read. A journal
            // reload can supersede another reload while either is suspended.
            if selectedScope == currentScopeFilter() {
                items = items.compactMap { row in
                    guard ids.contains(row.id) else { return row }
                    guard destinationIsVisible == true else { return nil }
                    return SavedItemSummary(id: row.id, itemTypeID: row.itemTypeID,
                        itemTypeName: row.itemTypeName, title: row.title, subtitle: row.subtitle,
                        cardCount: row.cardCount, deckID: deckID, createdAt: row.createdAt,
                        schedule: row.schedule)
                }
            }
            scheduleCommittedRefresh(browse: true, asOf: now)
            return outcome.value ?? outcome.affectedCount ?? 0
        } catch { errorMessage = UserFacingError.message(from: error); return 0 }
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
    func deleteItems(ids: Set<UUID>, scope: StudyScope = .allDecks, asOf now: Date = .now) async -> Int {
        errorMessage = nil
        do {
            let outcome = try await command("delete", count: ids.count) {
                try await NativeLibraryCommands.delete(on: library, ids: ids, asOf: now)
            }
            items.removeAll { ids.contains($0.id) }
            scheduleCommittedRefresh(asOf: now)
            return outcome.value ?? outcome.affectedCount ?? 0
        } catch { errorMessage = UserFacingError.message(from: error); return 0 }
    }

    func studyResponseCount(itemIDs: Set<UUID>) async -> Int {
        do {
            return try await library.studyResponseCount(itemIDs: itemIDs)
        } catch {
            errorMessage = UserFacingError.message(from: error)
            return 0
        }
    }

    private func command<Value: Sendable>(_ name: String, count: Int = 1,
        _ action: () async throws -> Value) async throws -> CommandOutcome<Value> {
        loadGeneration &+= 1
        defer { loadGeneration &+= 1 }
        let outcome = try await NativeLibraryCommands.perform(on: library,
            context: NativeCommandContext(operation: name, input: Data(), expectedCount: count), operation: action)
        lastCommandReceipt = outcome.receipt
        if let warning = outcome.warnings.first { errorMessage = warning }
        return outcome
    }

    private struct CommittedRefresh: Sendable {
        let scope: DeckScope
        let generation: UInt64
        let asOf: Date
        let browse: Bool
    }

    @ObservationIgnored private lazy var committedSummaryRefresh = LatestAsyncWork<CommittedRefresh> { [weak self] request in
        await self?.refreshCommittedSummary(request)
    }

    func awaitReadModels() async { await committedSummaryRefresh.waitUntilSettled() }

    private func scheduleCommittedRefresh(browse: Bool = false, asOf now: Date = .now) {
        if browse { browseDataInvalidated = true }
        let needsRows = browse || (browseDataInvalidated && loadedItemsScope != nil)
        committedSummaryRefresh.request(CommittedRefresh(scope: currentScopeFilter(),
            generation: loadGeneration, asOf: now, browse: needsRows))
    }

    private func refreshCommittedSummary(_ request: CommittedRefresh) async {
        guard request.generation == loadGeneration, request.scope == currentScopeFilter() else { return }
        do {
            var demand: Set<NativeLibraryReadDemand> = [.summary]
            if request.browse { demand.insert(.browse) }
            if !itemTypesLoaded { demand.insert(.catalog) }
            let snapshot = try await reads.load(scope: request.scope, demand: demand, asOf: request.asOf)
            guard request.generation == loadGeneration, request.scope == currentScopeFilter() else { return }
            if let catalog = snapshot.catalog {
                applyItemTypes(ItemTypeLoadResult(itemTypes: catalog.allItemTypes, corruptions: catalog.corruptions))
            }
            if let rows = snapshot.items {
                items = rows.sorted(using: tableSort)
                loadedItemsScope = request.scope
                browseDataInvalidated = false
            }
            if let summary = snapshot.summary { applyScopeSummary(summary, for: request.scope) }
            maturityUnavailable = snapshot.maturityIssue != nil
            errorMessage = snapshot.maturityIssue.map { "Maturity is unavailable. " + $0 } ?? itemTypeWarning
        } catch {
            guard request.generation == loadGeneration, request.scope == currentScopeFilter() else { return }
            errorMessage = "Saved. Refresh could not finish: \(error.localizedDescription)"
        }
    }

    /// Resolve descendant membership before committing, so publishing a move
    /// never waits for a read after the durable write. Older adapters may leave
    /// ancestry unknown; their optional browse refresh supplies the final rows.
    private func scopeContains(deckID: UUID?, scope: DeckScope) async -> Bool? {
        switch scope {
        case .allDecks: return true
        case .unassigned: return deckID == nil
        case let .deck(root, includeDescendants):
            guard var candidate = deckID else { return false }
            if candidate == root { return true }
            guard includeDescendants else { return false }
            guard let decks = library as? any LibraryDeckManaging else { return nil }
            var visited: Set<UUID> = []
            while visited.insert(candidate).inserted {
                guard let deck = try? await decks.deck(id: candidate) else { return nil }
                guard let parent = deck.parentID else { return false }
                if parent == root { return true }
                candidate = parent
            }
            return false
        }
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
            loadGeneration &+= 1
            browseDataInvalidated = true
        }
        cachedScope = scope
    }

    /// Re-reads the scheduling snapshot for the loaded scope without touching
    /// `isLoading` or the error banner. Cards come due while the app sits idle,
    /// so this is the path that keeps the headline honest between reloads.
    func refreshCounts(asOf now: Date = .now) async {
        let scope = currentScopeFilter()
        let generation = loadGeneration
        guard hasLoaded,
              let summary = try? await library.scopeSummary(
                  scope: scope,
                  asOf: now
              )
        else { return }

        guard generation == loadGeneration, scope == currentScopeFilter() else { return }
        applyScopeSummary(summary, for: scope)
    }

    /// Sync can change row content and schedules as well as the headline. Keep
    /// an unloaded browser lazy; update already-visible rows without a spinner.
    func refreshAfterSync(asOf now: Date = .now) async {
        invalidateItemTypes()
        browseDataInvalidated = true
        if loadedItemsScope != nil {
            await load(scope: cachedScope, asOf: now)
        } else {
            await refreshCounts(asOf: now)
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
