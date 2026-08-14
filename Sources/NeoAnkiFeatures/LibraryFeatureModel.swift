import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

public enum FeatureLoadState: Sendable, Equatable {
    case loading
    case ready
    case failed(UserFacingError)
}

public enum ItemDraftError: LocalizedError, Sendable, Equatable {
    case invalidNumber(String)
    case missingMediaDescription(String)
    case unsupportedValue(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidNumber(field): "Enter a valid localized number for \(field)."
        case let .missingMediaDescription(field): "Add a visual description for \(field)."
        case let .unsupportedValue(field): "\(field) could not be converted to its field type."
        }
    }
}

/// Platform-neutral, observable library workflow shared by Apple shells. It is
/// the only UI-facing owner of repository mutations, navigation state, browse
/// state, sync status, reminder recalculation, and widget publication.
@MainActor @Observable
public final class LibraryFeatureModel {
    public private(set) var loadState: FeatureLoadState = .loading
    public private(set) var allDecksSummary: ScopeSummary = .empty
    public private(set) var unassignedSummary: ScopeSummary = .empty
    public private(set) var decks: [DeckSummary] = []
    public private(set) var items: [SavedItemSummary] = []
    public private(set) var itemTypes: [ItemType] = []
    public private(set) var isRefreshing = false
    public private(set) var syncStatus: SyncStatus = .offline
    public private(set) var syncIssues: [SyncIssue] = []
    public private(set) var mediaStore: MediaStore?
    public private(set) var isStartingStudy = false
    public var activeStudy: StudyFeatureModel?
    public var section: AppSection = .home
    public var route: AppRoute = .scopeHome
    public var presentation: AppPresentation?
    public var selectedScope: DeckScope = .allDecks
    public var searchText = ""
    public var sortOrder: ItemSortOrder = .createdAscending
    public var concealsAnswers = true
    public var selectedItemIDs: Set<UUID> = []
    public var reminderSettings = ReminderSettings()
    public private(set) var syncEnabled = false

    public let library: any LibraryRepository
    private let syncService: any SyncService
    private let notifier: (any NotificationSchedulingService)?
    private let widgetPublisher: (any WidgetSnapshotPublishing)?
    private let settingsStore: (any MobileSettingsStoring)?
    private let errorMapper: any UserFacingErrorMapping
    private var deferredSyncTask: Task<Void, Never>?

    public init(
        library: any LibraryRepository,
        syncService: any SyncService = DisabledSyncService(),
        notifier: (any NotificationSchedulingService)? = nil,
        widgetPublisher: (any WidgetSnapshotPublishing)? = nil,
        settingsStore: (any MobileSettingsStoring)? = nil,
        errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper()
    ) {
        self.library = library
        self.syncService = syncService
        self.notifier = notifier
        self.widgetPublisher = widgetPublisher
        self.settingsStore = settingsStore
        self.errorMapper = errorMapper
    }

    public var visibleItems: [SavedItemSummary] {
        ItemBrowsing.arrange(items, sort: sortOrder, search: searchText)
    }

    public func bootstrap(startSync: Bool? = nil) async {
        loadState = .loading
        do {
            if let settingsStore {
                syncEnabled = await settingsStore.loadSyncEnabled()
                reminderSettings = await settingsStore.loadReminderSettings()
            }
            try await library.bootstrap()
            mediaStore = await library.mediaStore()
            try await reload()
            loadState = .ready
            if startSync ?? syncEnabled { await syncService.start(); await refreshSyncStatus() }
        } catch {
            loadState = .failed(errorMapper.map(error))
        }
    }

    public func reload(asOf now: Date = .now) async throws {
        isRefreshing = true
        defer { isRefreshing = false }
        async let home = library.coldHomeSnapshot(scope: .allDecks, asOf: now)
        async let loadedItems = library.items(scope: selectedScope, sort: sortOrder, search: "")
        async let catalog = library.loadItemTypeCatalog()
        let (snapshot, itemRows, typeCatalog) = try await (home, loadedItems, catalog)
        allDecksSummary = snapshot.allDecksSummary
        unassignedSummary = snapshot.unassignedSummary
        decks = snapshot.deckSummaries
        items = itemRows
        itemTypes = typeCatalog.allItemTypes
        selectedItemIDs.formIntersection(Set(itemRows.map(\.id)))
        await publishDeviceState(asOf: now)
    }

    public func refresh(asOf now: Date = .now) async {
        do { try await reload(asOf: now) }
        catch { loadState = .failed(errorMapper.map(error)) }
    }

    public func synchronize() async {
        guard syncEnabled else { return }
        await syncService.synchronize()
        await refreshSyncStatus()
        await refresh()
    }

    public func setSyncEnabled(_ enabled: Bool) async {
        syncEnabled = enabled
        await settingsStore?.saveSyncEnabled(enabled)
        if enabled { await syncService.start() } else { await syncService.stop() }
        await refreshSyncStatus()
    }

    public func setReminderSettings(_ settings: ReminderSettings) async throws {
        if settings.isEnabled, reminderSettings.isEnabled == false {
            if let notifier {
                let status = await notifier.authorizationStatus()
                if status == .denied { throw UserFacingError(title: "Reminders Are Disabled", message: "Allow notifications for NeoAnki2 in Settings to enable a daily reminder.") }
                if status == .notDetermined {
                    let granted = try await notifier.requestAuthorization()
                    if !granted {
                        throw UserFacingError(title: "Reminders Weren’t Enabled", message: "NeoAnki2 will continue working without notifications.")
                    }
                }
            }
        }
        reminderSettings = settings
        await settingsStore?.saveReminderSettings(settings)
        try await recalculateReminder()
    }

    public func refreshSyncStatus() async {
        syncStatus = await syncService.status()
        syncIssues = await syncService.issues()
    }

    public func retrySyncIssue(id: UUID) async {
        await syncService.retryIssue(id: id)
        await refreshSyncStatus()
        await refresh()
    }

    public func dismissSyncIssue(id: UUID) async {
        await syncService.dismissIssue(id: id)
        await refreshSyncStatus()
    }

    public func restoreSyncConflict(id: UUID) async throws {
        try await syncService.restoreConflictCopy(forIssueID: id)
        await refreshSyncStatus()
        try await reload()
    }

    public func handle(url: URL) -> Bool {
        guard let link = AppDeepLink(url: url) else { return false }
        route = link.route
        switch link {
        case let .scope(scope):
            selectedScope = scope
            section = .home
        case .item: section = .library
        case let .study(scope):
            section = .home
            let title: String = switch scope {
            case .allDecks: "All Decks"
            case .unassigned: "Unassigned"
            case let .deck(id, _): decks.first(where: { $0.id == id })?.name ?? "Deck"
            }
            Task { [weak self] in await self?.beginStudy(scope: scope, title: title) }
        }
        return true
    }

    public func scopeSummary(for scope: DeckScope, asOf now: Date = .now) async throws -> ScopeSummary {
        try await library.scopeSummary(scope: scope, asOf: now)
    }

    public func beginStudy(scope: DeckScope, title: String) async {
        guard !isStartingStudy else { return }
        isStartingStudy = true
        defer { isStartingStudy = false }
        let study = StudyFeatureModel(
            library: library,
            scope: scope,
            title: title,
            mediaStore: mediaStore,
            onMutation: { [weak self] in await self?.studyDidMutate() }
        )
        activeStudy = study
        await study.start()
    }

    public func endStudy() async {
        activeStudy = nil
        await refresh()
    }

    public func createDeck(name: String, parentID: UUID?, newCardsPerDay: Int?) async throws {
        _ = try await library.createDeck(Deck(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            parentID: parentID,
            newCardsPerDay: newCardsPerDay
        ))
        try await didMutate()
    }

    public func updateDeck(id: UUID, name: String, parentID: UUID?, newCardsPerDay: Int?) async throws {
        var deck = try await library.deck(id: id)
        deck.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deck.parentID = parentID
        deck.newCardsPerDay = newCardsPerDay
        _ = try await library.updateDeck(deck)
        try await didMutate()
    }

    public func deckDeletionImpact(id: UUID, policy: DeckDeletionPolicy) async throws -> DeckDeletionImpact {
        try await library.deckDeletionImpact(id: id, policy: policy)
    }

    public func deleteDeck(id: UUID, policy: DeckDeletionPolicy) async throws {
        try await library.commitDeckDeletion(id: id, policy: policy, asOf: .now)
        try await didMutate()
    }

    public func resetDeckProgress(id: UUID) async throws {
        _ = try await library.resetDeckProgress(id: id, asOf: .now)
        try await didMutate()
    }

    public func item(id: UUID) async throws -> (item: Item, itemType: ItemType)? {
        try await library.item(id: id)
    }

    public func createItem(itemType: ItemType, deckID: UUID?, values: [UUID: ContentValue]) async throws {
        let item = Item(
            itemTypeID: itemType.id,
            fields: itemType.fields.map { FieldValue(fieldID: $0.id, value: values[$0.id] ?? .empty) },
            deckID: deckID
        )
        _ = try await library.createItem(item, asOf: .now)
        try await didMutate()
    }

    public func updateItem(_ item: Item) async throws {
        _ = try await library.updateItem(item, asOf: .now)
        try await didMutate()
    }

    public func moveItems(_ ids: Set<UUID>, to deckID: UUID?) async throws {
        for id in ids { _ = try await library.moveItem(id: id, to: deckID) }
        try await didMutate()
    }

    public func deleteItems(_ ids: Set<UUID>) async throws {
        let operations = ids.sorted { $0.uuidString < $1.uuidString }.map {
            ItemBulkOperation(operationID: "delete-\($0.uuidString)", action: .delete($0))
        }
        if !operations.isEmpty {
            _ = try await library.performBulkItemOperations(operations, asOf: .now)
        }
        selectedItemIDs.subtract(ids)
        try await didMutate()
    }

    public func studyResponseCount(itemIDs: Set<UUID>) async throws -> Int {
        try await library.studyResponseCount(itemIDs: itemIDs)
    }

    public func studyResponseCount(templateIDs: Set<UUID>) async throws -> Int {
        try await library.studyResponseCount(templateIDs: templateIDs)
    }

    public func reserveMedia(data: Data, kind: MediaKind, altText: String) async throws -> MediaRef {
        let description = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw ItemDraftError.missingMediaDescription("Media") }
        return try await library.reserveMedia(data: data, kind: kind, altText: description, asOf: .now).reference
    }

    public func importJSON(_ data: Data, itemTypeID: UUID?, deckID: UUID?) async throws -> Int {
        let imported = try await library.importJSONItems(
            from: data,
            itemTypeID: itemTypeID,
            context: ImportContext(),
            asOf: .now
        )
        if let deckID {
            for item in imported { _ = try await library.moveItem(id: item.id, to: deckID) }
        }
        try await didMutate()
        return imported.count
    }

    public func importCSV(_ data: Data, itemTypeID: UUID?, itemTypeName: String, deckID: UUID?) async throws -> Int {
        let imported = try await library.importCSVItems(
            from: data,
            itemTypeID: itemTypeID,
            itemTypeName: itemTypeName,
            context: ImportContext(),
            asOf: .now
        )
        if let deckID {
            for item in imported { _ = try await library.moveItem(id: item.id, to: deckID) }
        }
        try await didMutate()
        return imported.count
    }

    public func importPortableDeck(from url: URL, conflict: PortableDeckTypeConflictResolution) async throws -> PortableDeckImportResult {
        let result = try await library.importPortableDeck(from: url, conflictResolution: conflict)
        try await didMutate()
        return result
    }

    public func importAuthoredBundle(from url: URL) async throws -> PortableDeckImportResult {
        let result = try await library.importAuthoredDeck(from: url)
        try await didMutate()
        return result
    }

    public func exportDeck(id: UUID, to url: URL) async throws {
        try await library.exportPortableDeck(id: id, to: url)
    }

    public func createItemType(_ type: ItemType) async throws {
        _ = try await library.createItemType(type)
        try await didMutate()
    }

    public func updateItemType(_ type: ItemType) async throws {
        _ = try await library.updateItemType(type, asOf: .now)
        try await didMutate()
    }

    public func duplicateItemType(id: UUID, name: String) async throws {
        _ = try await library.duplicateItemType(id: id, name: name)
        try await didMutate()
    }

    public func repairItemType(id: UUID) async throws {
        _ = try await library.repairItemTypeDefinition(id: id, asOf: .now)
        try await didMutate()
    }

    public func deleteItemType(id: UUID) async throws {
        _ = try await library.deleteItemType(id: id)
        try await didMutate()
    }

    public func recalculateReminder(asOf now: Date = .now) async throws {
        guard reminderSettings.isEnabled else {
            try await notifier?.replaceDailyReminder(nil)
            return
        }
        let due = try await library.dueCount(scope: reminderSettings.scope.deckScope, asOf: now)
        let request = due > 0 ? DailyReminderRequest(
            hour: reminderSettings.hour,
            minute: reminderSettings.minute,
            scope: reminderSettings.scope,
            dueCount: due
        ) : nil
        try await notifier?.replaceDailyReminder(request)
    }

    private func didMutate() async throws {
        try await reload()
        scheduleDebouncedSync()
    }

    private func studyDidMutate(asOf now: Date = .now) async {
        if let summary = try? await library.scopeSummary(scope: .allDecks, asOf: now) {
            allDecksSummary = summary
        }
        await publishDeviceState(asOf: now)
        scheduleDebouncedSync()
    }

    private func scheduleDebouncedSync() {
        guard syncEnabled else { return }
        deferredSyncTask?.cancel()
        deferredSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            await self.syncService.synchronize()
            await self.refreshSyncStatus()
        }
    }

    private func publishDeviceState(asOf now: Date) async {
        try? await recalculateReminder(asOf: now)
        let deckSnapshots = await withTaskGroup(of: DueWidgetDeckSummary?.self) { group in
            for deck in decks.prefix(12) {
                group.addTask { [library] in
                    guard let summary = try? await library.scopeSummary(scope: .deck(deck.id), asOf: now) else { return nil }
                    return DueWidgetDeckSummary(id: deck.id, name: deck.name, dueCount: summary.dueNow, nextDueAt: summary.nextStudyAt)
                }
            }
            var values: [DueWidgetDeckSummary] = []
            for await value in group { if let value { values.append(value) } }
            return values.sorted { lhs, rhs in
                if lhs.dueCount != rhs.dueCount { return lhs.dueCount > rhs.dueCount }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        try? await widgetPublisher?.publish(DueWidgetSnapshot(
            totalDueCount: allDecksSummary.dueNow,
            nextDueAt: allDecksSummary.nextStudyAt,
            decks: deckSnapshots,
            updatedAt: now
        ))
    }
}
