import BackgroundTasks
import Foundation
import NeoAnkiApplication
import NeoAnkiCloudSync
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

@MainActor final class IOSBackgroundRefresh {
    static let shared = IOSBackgroundRefresh()
    private let identifier = "com.neoanki2.ios.refresh"
    private weak var model: LibraryFeatureModel?
    func register(model: LibraryFeatureModel) {
        self.model = model
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
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
            if model.syncEnabled { await model.synchronize() }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
