import BackgroundTasks
import Foundation
import NeoAnkiApplication
import NeoAnkiCloudSync
import NeoAnkiCore
import NeoAnkiFeatures
import UserNotifications
import WidgetKit

actor IOSMobileSettingsStore: MobileSettingsStoring {
    private let defaults: UserDefaults
    private let syncKey = "cloud-sync-enabled-v1"
    private let reminderKey = "reminder-settings-v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadSyncEnabled() async -> Bool { defaults.bool(forKey: syncKey) }
    func saveSyncEnabled(_ enabled: Bool) async { defaults.set(enabled, forKey: syncKey) }
    func loadReminderSettings() async -> ReminderSettings {
        guard let data = defaults.data(forKey: reminderKey),
              let settings = try? JSONDecoder().decode(ReminderSettings.self, from: data)
        else { return ReminderSettings() }
        return settings
    }
    func saveReminderSettings(_ settings: ReminderSettings) async {
        defaults.set(try? JSONEncoder().encode(settings), forKey: reminderKey)
    }
}

actor IOSNotificationScheduler: NotificationSchedulingService {
    private let center = UNUserNotificationCenter.current()
    func authorizationStatus() async -> NotificationAuthorizationStatus {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .ephemeral: .authorized
        case .provisional: .provisional
        @unknown default: .denied
        }
    }
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func replaceDailyReminder(_ request: DailyReminderRequest?) async throws {
        let id = "neoanki2.daily-reminder"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let request, request.dueCount > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cards are ready"
        content.body = "\(request.dueCount) \(request.dueCount == 1 ? "card is" : "cards are") due."
        content.sound = .default
        content.userInfo["url"] = reminderURL(request.scope).absoluteString
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(hour: request.hour, minute: request.minute),
            repeats: true
        )
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
    private func reminderURL(_ scope: ReminderScope) -> URL {
        switch scope {
        case .allDecks: URL(string: "neoanki2://study?kind=all")!
        case let .deck(id): URL(string: "neoanki2://study?kind=deck&id=\(id.uuidString)")!
        }
    }
}

actor AppGroupWidgetPublisher: WidgetSnapshotPublishing {
    private let suite = UserDefaults(suiteName: "group.com.neoanki2.shared")
    func publish(_ snapshot: DueWidgetSnapshot) async throws {
        suite?.set(try JSONEncoder().encode(snapshot), forKey: "due-widget-snapshot-v1")
        WidgetCenter.shared.reloadTimelines(ofKind: "NeoAnkiDueWidget")
    }
}

actor MobileSyncCoordinator: SyncService {
    private let repository: SQLiteLibraryRepository
    private let paths: MobilePaths
    private var service: (any SyncService)?
    private var fallbackStatus: SyncStatus = .offline

    init(repository: SQLiteLibraryRepository, paths: MobilePaths) {
        self.repository = repository
        self.paths = paths
    }

    func start() async {
        do {
            let metadata = SyncMetadataStore(directory: paths.syncMetadataDirectory)
            let transport = try await CKSyncEngineTransport.make(metadataStore: metadata)
            let adapter = SQLiteLibrarySyncAdapter(repository: repository)
            let service = OfflineFirstSyncService(
                repository: repository,
                adapter: adapter,
                transport: transport,
                metadataStore: metadata,
                backupURL: { [paths] in paths.backupURL }
            )
            self.service = service
            await service.start()
        } catch { fallbackStatus = .accountUnavailable }
    }
    func synchronize() async { await service?.synchronize() }
    func stop() async { await service?.stop(); fallbackStatus = .offline }
    func status() async -> SyncStatus { if let service { return await service.status() }; return fallbackStatus }
    func issues() async -> [SyncIssue] { await service?.issues() ?? [] }
    func retryIssue(id: UUID) async { await service?.retryIssue(id: id) }
    func dismissIssue(id: UUID) async { await service?.dismissIssue(id: id) }
    func restoreConflictCopy(forIssueID id: UUID) async throws {
        guard let service else { throw UserFacingError(title: "Sync Is Offline", message: "Reconnect to iCloud and try again.") }
        try await service.restoreConflictCopy(forIssueID: id)
    }
}

/// Reset-only Simulator fixture. Uses the production codec and restore adapter
/// while keeping visual recovery acceptance independent of a signed account.
actor MobileSyncRecoveryUITestService: SyncService {
    private let repository: SQLiteLibraryRepository
    private let adapter: SQLiteLibrarySyncAdapter
    private var seeded = false
    private var pending: [SyncIssue] = []

    init(repository: SQLiteLibraryRepository) {
        self.repository = repository
        adapter = SQLiteLibrarySyncAdapter(repository: repository)
    }
    func start() async {
        guard !seeded else { return }
        seeded = true
        do {
            let deck = Deck(name: "Preserved reading deck")
            _ = try await repository.createDeck(deck)
            let records = try await adapter.encode(
                changes: repository.changes(after: 0, limit: 1_000), deviceID: "visual-fixture")
            guard let record = records.first(where: { $0.id == deck.id.uuidString && $0.resourceKind == "deck" }) else { return }
            let copy = SyncConflictCopy(resourceKind: "deck", originalResourceID: record.id,
                                        sourceDeviceID: "another-device", payload: record.payload)
            let invalid = SyncConflictCopy(resourceKind: "deck", originalResourceID: UUID().uuidString,
                                           sourceDeviceID: "another-device", payload: Data("invalid".utf8))
            pending = [
                SyncIssue(kind: .deckConflict, resourceID: record.id,
                          summary: "Another device changed this deck. Your earlier version is preserved.", conflictCopy: copy),
                SyncIssue(kind: .invalidRemoteChange, resourceID: invalid.originalResourceID,
                          summary: "This preserved copy could not be verified. Retry or dismiss this issue.", conflictCopy: invalid),
            ]
        } catch {
            pending = [SyncIssue(kind: .invalidRemoteChange, resourceID: "visual-fixture",
                                 summary: error.localizedDescription)]
        }
    }
    func synchronize() async {}
    func stop() async {}
    func status() async -> SyncStatus { pending.isEmpty ? .current(lastSync: .now) : .needsAttention(issueCount: pending.count) }
    func issues() async -> [SyncIssue] { pending }
    func retryIssue(id: UUID) async {}
    func dismissIssue(id: UUID) async { pending.removeAll { $0.id == id } }
    func restoreConflictCopy(forIssueID id: UUID) async throws {
        guard let copy = pending.first(where: { $0.id == id })?.conflictCopy else { return }
        try await adapter.restoreConflictCopy(copy)
        pending.removeAll { $0.id == id }
    }
}

@MainActor final class IOSBackgroundRefresh {
    static let shared = IOSBackgroundRefresh()
    private let identifier = "com.neoanki2.ios.refresh"
    private weak var model: LibraryFeatureModel?
    func register(model: LibraryFeatureModel) {
        self.model = model
        // Swift inherits this callback's MainActor isolation. A nil queue makes
        // BGTaskScheduler invoke it off-main and traps before the handler runs.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self?.handle(refresh)
        }
    }
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    private func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { [weak self] in
            guard let model = self?.model else { task.setTaskCompleted(success: false); return }
            await model.refresh()
            guard !Task.isCancelled else { task.setTaskCompleted(success: false); return }
            if model.syncEnabled { await model.synchronize() }
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        // The system can also expire a task off-main. Capturing only the
        // Sendable work handle avoids inheriting MainActor on this callback.
        task.expirationHandler = { @Sendable in work.cancel() }
    }
}
