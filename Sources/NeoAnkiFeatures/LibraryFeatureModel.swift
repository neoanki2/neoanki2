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

/// Mobile library presentation and device publication. Both native shells use
/// the shared application commands and read coordinator; navigation and native
/// table/editor behavior remain in their presentation adapters.
@MainActor @Observable
public final class LibraryFeatureModel {
    public private(set) var loadState: FeatureLoadState = .loading
    public private(set) var allDecksSummary: ScopeSummary = .empty
    public private(set) var unassignedSummary: ScopeSummary = .empty
    public private(set) var decks: [DeckSummary] = []
    public private(set) var items: [SavedItemSummary] = []
    public private(set) var itemTypes: [ItemType] = []
    public private(set) var includedItemTypeGroups: [IncludedItemTypeGroup] = []
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

    public private(set) var recoveryMessage: String?
    public private(set) var lastCommandReceipt: NativeCommandReceipt?
    public private(set) var libraryRevision: UInt64 = 0
    private let reads: NativeLibraryReadCoordinator
    private var readGeneration: UInt64 = 0
    private var browseRequested = false
    private var commandRefreshInProgress = false
    @ObservationIgnored private var libraryChangesTask: Task<Void, Never>?

    public let library: any LibraryRepository
    private let syncService: any SyncService
    private let notifier: (any NotificationSchedulingService)?
    private let widgetPublisher: (any WidgetSnapshotPublishing)?
    private let badgePublisher: (any AppIconBadgePublishing)?
    private let settingsStore: (any MobileSettingsStoring)?
    private let errorMapper: any UserFacingErrorMapping
    @ObservationIgnored private var syncChangesTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var studyUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var studyUpdatesRequested = false
    @ObservationIgnored private var studyMutationRevision: UInt64 = 0
    @ObservationIgnored private var devicePublicationTask: Task<Void, Never>?
    @ObservationIgnored private var devicePublicationRevision: UInt64 = 0

    deinit {
        libraryChangesTask?.cancel(); syncChangesTask?.cancel(); bootstrapTask?.cancel()
        studyUpdatesTask?.cancel(); devicePublicationTask?.cancel()
    }

    private func observeSyncChanges() async {
        syncChangesTask?.cancel()
        let changes = await syncService.libraryChanges()
        syncChangesTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
                await self.refreshSyncStatus()
            }
        }
    }

    public init(
        library: any LibraryRepository,
        syncService: any SyncService = DisabledSyncService(),
        notifier: (any NotificationSchedulingService)? = nil,
        widgetPublisher: (any WidgetSnapshotPublishing)? = nil,
        badgePublisher: (any AppIconBadgePublishing)? = nil,
        settingsStore: (any MobileSettingsStoring)? = nil,
        errorMapper: any UserFacingErrorMapping = DefaultUserFacingErrorMapper()
    ) {
        self.library = library
        self.reads = NativeLibraryReadCoordinator(library: library)
        self.syncService = syncService
        self.notifier = notifier
        self.widgetPublisher = widgetPublisher
        self.badgePublisher = badgePublisher
        self.settingsStore = settingsStore
        self.errorMapper = errorMapper
    }

    /// The stricter capability set required by Item Type Studio. Legacy
    /// `LibraryRepository` conformers remain source-compatible and simply do
    /// not vend a Studio until they adopt editing safeguards.
    public var itemTypeStudioLibrary:
        (any LibraryBrowsing
            & LibraryItemTypeManaging
            & LibraryItemTypeEditingSafeguarding
            & LibraryItemTypeStudioSaving)?
    {
        library as? any LibraryBrowsing
            & LibraryItemTypeManaging
            & LibraryItemTypeEditingSafeguarding
            & LibraryItemTypeStudioSaving
    }

    public var visibleItems: [SavedItemSummary] {
        ItemBrowsing.arrange(items, sort: sortOrder, search: searchText)
    }

    public func bootstrap(startSync: Bool? = nil) async {
        if let bootstrapTask { await bootstrapTask.value; return }
        let task = Task<Void, Never> { [weak self] in
            await self?.performBootstrap(startSync: startSync)
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func performBootstrap(startSync: Bool?) async {
        loadState = .loading
        do {
            if let settingsStore {
                syncEnabled = await settingsStore.loadSyncEnabled()
                reminderSettings = await settingsStore.loadReminderSettings()
            }
            try await library.bootstrap()
            mediaStore = await library.mediaStore()
            try await reload(demand: [.home, .catalog])
            loadState = .ready
            await observeLibraryChanges()
            if startSync ?? syncEnabled {
                await observeSyncChanges()
                await syncService.start()
                await refreshSyncStatus()
                try await reload(demand: [.home, .catalog])
            }
        } catch {
            loadState = .failed(errorMapper.map(error))
        }
    }

    private func observeLibraryChanges() async {
        libraryChangesTask?.cancel()
        let stream = await reads.invalidations()
        libraryChangesTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                libraryRevision &+= 1
                if !commandRefreshInProgress { await refresh() }
            }
        }
    }

    public func loadBrowse(scope: DeckScope) async throws -> [SavedItemSummary] {
        browseRequested = true
        let snapshot = try await reads.load(scope: scope, demand: [.browse], asOf: .now)
        if scope == selectedScope { items = snapshot.items ?? [] }
        return snapshot.items ?? []
    }

    public func reload(asOf now: Date = .now,
        demand: Set<NativeLibraryReadDemand> = [.home, .browse, .catalog]) async throws {
        readGeneration &+= 1
        let generation = readGeneration
        let scope = selectedScope
        let sort = sortOrder
        isRefreshing = true
        defer { if generation == readGeneration { isRefreshing = false } }
        var snapshotTime = now
        while true {
            let revision = studyMutationRevision
            await finishStudyUpdates()
            if revision != studyMutationRevision { snapshotTime = max(snapshotTime, .now); continue }
            let data = try await reads.load(scope: scope, sort: sort, demand: demand, asOf: snapshotTime)
            guard generation == readGeneration, scope == selectedScope, sort == sortOrder else { return }
            guard revision == studyMutationRevision else { snapshotTime = max(snapshotTime, .now); continue }
            if let snapshot = data.home {
                allDecksSummary = snapshot.allDecksSummary
                unassignedSummary = snapshot.unassignedSummary
                decks = snapshot.deckSummaries
                itemTypes = snapshot.itemTypes.itemTypes
            }
            if let rows = data.items {
                browseRequested = true
                items = rows
                selectedItemIDs.formIntersection(Set(rows.map(\.id)))
            }
            if let catalog = data.catalog {
                itemTypes = catalog.allItemTypes
                includedItemTypeGroups = catalog.includedWithDecks
            }
            recoveryMessage = data.maturityIssue.map { "Maturity is unavailable. " + $0 }
            await publishDeviceState(asOf: snapshotTime)
            return
        }
    }

    public func refresh(asOf now: Date = .now) async {
        do { try await reload(asOf: now, demand: browseRequested ? [.home, .browse, .catalog] : [.home, .catalog]) }
        catch { loadState = .failed(errorMapper.map(error)) }
    }

    /// A shared authoring workflow committed through the repository. Publish counts and schedule sync.
    public func authoringDidCommit() async {
        await refresh()
    }

    public func synchronize() async {
        guard syncEnabled else { return }
        await syncService.synchronizeAndWait()
        await refreshSyncStatus()
        await refresh()
    }

    public func setSyncEnabled(_ enabled: Bool) async {
        syncEnabled = enabled
        await settingsStore?.saveSyncEnabled(enabled)
        if enabled {
            await observeSyncChanges()
            await syncService.start()
        } else {
            syncChangesTask?.cancel()
            syncChangesTask = nil
            await syncService.stop()
        }
        await refreshSyncStatus()
        if enabled { await refresh() }
    }

    public func setReminderSettings(_ settings: ReminderSettings) async throws {
        if settings.isEnabled, reminderSettings.isEnabled == false {
            if let notifier {
                let status = await notifier.authorizationStatus()
                if status == .denied { throw UserFacingError(title: "Reminders Are Disabled", message: "Allow notifications for NeoAnki2 in Settings to enable a daily reminder.") }
                // Overall authorization may cover only app-icon badges. Ask
                // for the reminder's alert/sound capabilities when enabled.
                let granted = try await notifier.requestAuthorization()
                if !granted {
                    throw UserFacingError(title: "Reminders Weren’t Enabled", message: "NeoAnki2 will continue working without notifications.")
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
        let data = try await reads.load(scope: scope, demand: [.summary], asOf: now)
        if let issue = data.maturityIssue { recoveryMessage = "Maturity is unavailable. " + issue }
        return data.summary ?? .empty
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
        _ = try await command("create-deck") { try await library.createDeck(Deck(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            parentID: parentID,
            newCardsPerDay: newCardsPerDay
        )) }
        try await didMutate()
    }

    public func updateDeck(id: UUID, name: String, parentID: UUID?, newCardsPerDay: Int?) async throws {
        var deck = try await library.deck(id: id)
        deck.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deck.parentID = parentID
        deck.newCardsPerDay = newCardsPerDay
        _ = try await command("update-deck", input: try JSONEncoder().encode(deck)) { try await library.updateDeck(deck) }
        try await didMutate()
    }

    public func deckDeletionImpact(id: UUID, policy: DeckDeletionPolicy) async throws -> DeckDeletionImpact {
        try await library.deckDeletionImpact(id: id, policy: policy)
    }

    public func deleteDeck(id: UUID, policy: DeckDeletionPolicy) async throws {
        _ = try await command("delete-deck", input: Data(id.uuidString.utf8)) { try await library.commitDeckDeletion(id: id, policy: policy, asOf: .now) }
        try await didMutate()
    }

    public func resetDeckProgress(id: UUID) async throws {
        _ = try await command("reset-deck", input: Data(id.uuidString.utf8)) { try await library.resetDeckProgress(id: id, asOf: .now) }
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
        _ = try await command("create-item", input: try JSONEncoder().encode(item)) { try await library.createItem(item, asOf: .now) }
        try await didMutate()
    }

    public func updateItem(_ item: Item) async throws {
        let updated: Item
        if let stored = try await library.item(id: item.id) {
            updated = ContextDerivedContent.invalidatingSpeech(in: item, original: stored.item, type: stored.itemType)
        } else { updated = item }
        _ = try await command("update-item", input: try JSONEncoder().encode(updated)) { try await library.updateItem(updated, asOf: .now) }
        try await didMutate()
    }

    public func moveItems(_ ids: Set<UUID>, to deckID: UUID?, rows: [SavedItemSummary]? = nil) async throws {
        let selection = try NativeLibraryCommands.selection(ids, rows: rows ?? items)
        _ = try await command("move", input: Data(ids.sorted { $0.uuidString < $1.uuidString }.description.utf8), count: ids.count) {
            try await NativeLibraryCommands.move(on: library, selection: selection, to: deckID)
        }
        try await didMutate()
    }

    public func deleteItems(_ ids: Set<UUID>) async throws {
        _ = try await command("delete", input: Data(ids.sorted { $0.uuidString < $1.uuidString }.description.utf8), count: ids.count) {
            try await NativeLibraryCommands.delete(on: library, ids: ids, asOf: .now)
        }
        selectedItemIDs.subtract(ids)
        try await didMutate()
    }

    public func studyResponseCount(itemIDs: Set<UUID>) async throws -> Int {
        try await library.studyResponseCount(itemIDs: itemIDs)
    }

    /// Compatibility query retained for clients that inspect response impact
    /// outside Item Type Studio.
    public func studyResponseCount(templateIDs: Set<UUID>) async throws -> Int {
        try await library.studyResponseCount(templateIDs: templateIDs)
    }

    public func reserveMedia(data: Data, kind: MediaKind, altText: String) async throws -> MediaRef {
        let description = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = kind == .image ? try await AttachmentImagePreparer.prepare(data: data).data : data
        try Task.checkCancellation()
        return try await library.reserveMedia(data: bytes, kind: kind, altText: description, asOf: .now).reference
    }

    public func importJSON(_ data: Data, itemTypeID: UUID?, deckID: UUID?) async throws -> Int {
        let outcome = try await command("import-json", input: data) {
            try await NativeLibraryCommands.importItems(on: library, data: data, format: .json,
                itemTypeID: itemTypeID, deckID: deckID, context: ImportContext(), asOf: .now)
        }
        try await didMutate()
        return outcome.value?.count ?? outcome.affectedCount ?? 0
    }

    public func importCSV(_ data: Data, itemTypeID: UUID?, itemTypeName: String, deckID: UUID?) async throws -> Int {
        let outcome = try await command("import-csv", input: data) {
            try await NativeLibraryCommands.importItems(on: library, data: data, format: .csv(itemTypeName: itemTypeName),
                itemTypeID: itemTypeID, deckID: deckID, context: ImportContext(), asOf: .now)
        }
        try await didMutate()
        return outcome.value?.count ?? outcome.affectedCount ?? 0
    }

    public func importPortableDeck(from url: URL, conflict: PortableDeckTypeConflictResolution) async throws -> PortableDeckImportResult {
        let result = try await NativeLibraryCommands.importDeck(on: library, source: url, authored: false, conflict: conflict)
        try await didMutate()
        return result
    }

    public func importAuthoredBundle(from url: URL) async throws -> PortableDeckImportResult {
        let result = try await NativeLibraryCommands.importDeck(on: library, source: url, authored: true)
        try await didMutate()
        return result
    }

    public func exportDeck(id: UUID, to url: URL) async throws {
        try await library.exportPortableDeck(id: id, to: url)
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel for atomic Item Type Studio saves.")
    public func createItemType(_ type: ItemType) async throws {
        _ = try await library.createItemType(type)
        try await didMutate()
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel.prepareSave() and commitSave(_:asOf:).")
    public func updateItemType(_ type: ItemType) async throws {
        _ = try await library.updateItemType(type, asOf: .now)
        try await didMutate()
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel duplicate workflows.")
    public func duplicateItemType(id: UUID, name: String) async throws {
        _ = try await library.duplicateItemType(id: id, name: name)
        try await didMutate()
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel catalog and read-only selection state.")
    public func includedItemTypeOwner(id: UUID) -> IncludedItemTypeGroup? {
        includedItemTypeGroups.first { group in
            group.itemTypes.contains { $0.id == id }
        }
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel editing-impact workflows.")
    public func itemTypeEditingImpact(id: UUID) async throws -> ItemTypeEditingImpact {
        try await itemTypeEditingSafeguards.itemTypeEditingImpact(id: id)
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel unlock workflows.")
    public func unlockItemType(id: UUID) async throws {
        _ = try await itemTypeEditingSafeguards.unlockItemType(id: id)
        try await didMutate()
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel.prepareSave() for aggregated impact.")
    public func itemTypeSchemaChangeImpact(
        from existing: ItemType,
        to updated: ItemType
    ) async throws -> ItemTypeSchemaChangeImpact {
        try await itemTypeEditingSafeguards.itemTypeSchemaChangeImpact(
            from: existing,
            to: updated
        )
    }

    private var itemTypeEditingSafeguards: any LibraryItemTypeEditingSafeguarding {
        get throws {
            guard let safeguards = library as? any LibraryItemTypeEditingSafeguarding else {
                throw DatabaseError.invalidItemType(
                    "This library does not support unlocking deck-provided item types."
                )
            }
            return safeguards
        }
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel repair workflows.")
    public func repairItemType(id: UUID) async throws {
        _ = try await library.repairItemTypeDefinition(id: id, asOf: .now)
        try await didMutate()
    }

    @available(*, deprecated, message: "Use ItemTypesFeatureModel deletion workflows.")
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
        commandRefreshInProgress = true
        defer { commandRefreshInProgress = false }
        libraryRevision &+= 1
        do { try await reload(demand: browseRequested ? [.home, .browse, .catalog] : [.home, .catalog]) }
        catch { recoveryMessage = "Saved. Refresh could not finish: \(error.localizedDescription)" }
    }

    private func command<Value: Sendable>(_ name: String, input: Data = Data(), count: Int = 1,
        _ operation: () async throws -> Value) async throws -> CommandOutcome<Value> {
        let outcome = try await NativeLibraryCommands.perform(on: library,
            context: NativeCommandContext(operation: name, input: input, expectedCount: count), operation: operation)
        lastCommandReceipt = outcome.receipt
        if let warning = outcome.warnings.first { recoveryMessage = warning }
        return outcome
    }

    private func studyDidMutate() async {
        // The review is durable and the next card is validated before this
        // callback. OS publication and library-wide summaries are not part of
        // saving a review; a suspended publisher must never hold study controls.
        studyMutationRevision &+= 1
        studyUpdatesRequested = true
        guard studyUpdatesTask == nil else { return }
        studyUpdatesTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { studyUpdatesTask = nil }
            repeat {
                studyUpdatesRequested = false
                let revision = studyMutationRevision
                let now = Date.now
                let availability = try? await studyAvailability(scope: .allDecks, asOf: now)
                guard !Task.isCancelled else { return }
                guard revision == studyMutationRevision else { continue }
                if let availability { await publishDeviceState(asOf: now, availability: availability) }
            } while studyUpdatesRequested && !Task.isCancelled
        }
    }

    private func finishStudyUpdates() async {
        while let task = studyUpdatesTask { await task.value }
    }

    private func studyAvailability(scope: DeckScope, asOf now: Date) async throws -> StudyAvailability {
        if let reader = library as? any LibraryStudyAvailabilityReading {
            return try await reader.studyAvailability(scope: scope, asOf: now)
        }
        let summary = try await library.scopeSummary(scope: scope, asOf: now)
        return StudyAvailability(dueNow: summary.dueNow, nextStudyAt: summary.nextStudyAt)
    }

    private func publishDeviceState(asOf now: Date, availability: StudyAvailability? = nil) async {
        // Serialize publication so an older, suspended OS request cannot
        // finish after a newer grade/undo and restore stale device counts.
        let previous = devicePublicationTask
        let mutationRevision = studyMutationRevision
        let availability = availability ?? StudyAvailability(dueNow: allDecksSummary.dueNow,
            nextStudyAt: allDecksSummary.nextStudyAt)
        devicePublicationRevision &+= 1
        let revision = devicePublicationRevision
        let task = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            guard mutationRevision == studyMutationRevision else { return }
            await performDeviceStatePublication(asOf: now, availability: availability)
        }
        devicePublicationTask = task
        await task.value
        if revision == devicePublicationRevision { devicePublicationTask = nil }
    }

    private func performDeviceStatePublication(asOf now: Date, availability: StudyAvailability) async {
        let widgetDecks = Array(decks.prefix(12))
        do { try await badgePublisher?.publish(AppIconBadge(dueCount: availability.dueNow)) }
        catch { recoveryMessage = "Saved. Device updates could not finish: " + error.localizedDescription }
        do { try await recalculateReminder(asOf: now) }
        catch { recoveryMessage = "Saved. Device updates could not finish: " + error.localizedDescription }
        guard let widgetPublisher else { return }
        var deckSnapshots: [DueWidgetDeckSummary] = []
        // Keep these lightweight reads sequential rather than queuing a burst
        // of device-service queries ahead of the next review write.
        for deck in widgetDecks {
            guard !Task.isCancelled else { return }
            guard let summary = try? await studyAvailability(scope: .deck(deck.id), asOf: now) else { continue }
            deckSnapshots.append(DueWidgetDeckSummary(id: deck.id, name: deck.name,
                dueCount: summary.dueNow, nextDueAt: summary.nextStudyAt))
        }
        deckSnapshots.sort { lhs, rhs in
            if lhs.dueCount != rhs.dueCount { return lhs.dueCount > rhs.dueCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        do { try await widgetPublisher.publish(DueWidgetSnapshot(
            totalDueCount: availability.dueNow,
            nextDueAt: availability.nextStudyAt,
            decks: deckSnapshots,
            updatedAt: now
        )) } catch { recoveryMessage = "Saved. Device updates could not finish: " + error.localizedDescription }
    }
}
