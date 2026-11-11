import NeoAnkiApplication
import NeoAnkiFeatures
import NeoAnkiCloudSync
import NeoAnkiVocabularyKit
import NeoAnkiMobile
import SwiftUI
import UIKit
import OSLog

@main
struct NeoAnkiIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSCloudSyncAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: LibraryFeatureModel
    private var packCloudTransport: (any VocabularyPackCloudTransport)? {
        if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset") {
            return MobileVocabularyCloudUITestTransport.makeIfRequested()
        }
        return CKVocabularyPackCloudTransport()
    }

    private var usesAccessibilityUITestEnvironment: Bool {
        ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingAccessibility")
    }

    private var usesCardSetupAccessibilityTestHost: Bool {
        let process = ProcessInfo.processInfo
        return process.arguments.contains("-NeoAnkiUITestingReset")
            && process.arguments.contains("-NeoAnkiUITestingAccessibility")
            && process.arguments.contains("-NeoAnkiUITestingCardSetupAccessibilityEditor")
            && process.environment["NEOANKI_TEST_SCENARIO"] == "item-type-studio"
    }

    init() {
        let paths = MobilePaths()
        let usesAccessibilityUITestEnvironment = ProcessInfo.processInfo.arguments.contains(
            "-NeoAnkiUITestingAccessibility"
        )
        if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset") {
            // Keep ordinary UI journeys deterministic, but leave UIKit motion
            // enabled for the accessibility matrix so the injected SwiftUI
            // reduced-motion environment remains the behavior under test.
            UIView.setAnimationsEnabled(usesAccessibilityUITestEnvironment)
            let fileManager = FileManager.default
            for url in [
                paths.databaseURL,
                URL(fileURLWithPath: paths.databaseURL.path + "-wal"),
                URL(fileURLWithPath: paths.databaseURL.path + "-shm"),
                paths.syncMetadataDirectory,
                paths.backupURL,
                paths.vocabularyPacksURL,
            ] {
                try? fileManager.removeItem(at: url)
            }
            UserDefaults.standard.removeObject(forKey: "mobile-conceals-answers")
            UserDefaults.standard.removeObject(forKey: "usesPassFailGrades")
            UserDefaults.standard.removeObject(forKey: "cloud-sync-enabled-v1")
            UserDefaults.standard.removeObject(forKey: "reminder-settings-v1")
        }
        let repository = try! SQLiteLibraryRepository(databaseURL: paths.databaseURL)
        let usesSyncFixture = ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset")
            && ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] == "mobile-sync-recovery"
        let usesPackFixture = ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset")
            && ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] == "mobile-vocabulary-cloud"
        if usesSyncFixture || usesPackFixture { UserDefaults.standard.set(true, forKey: "cloud-sync-enabled-v1") }
        let syncService: any SyncService
        if usesPackFixture { syncService = DisabledSyncService() }
        else if usesSyncFixture { syncService = MobileSyncRecoveryUITestService(repository: repository) }
        else { syncService = MobileSyncCoordinator(repository: repository, paths: paths) }
        let model = LibraryFeatureModel(
            library: repository,
            syncService: syncService,
            notifier: IOSNotificationScheduler(),
            widgetPublisher: AppGroupWidgetPublisher(),
            badgePublisher: IOSAppIconBadgePublisher(),
            settingsStore: IOSMobileSettingsStore()
        )
        _model = State(initialValue: model)
        IOSCloudSyncAppDelegate.model = model
        IOSBackgroundRefresh.shared.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset") && ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] == "image-occlusion" {
                MobileImageOcclusionTestHost(model: model)
            } else if usesAccessibilityUITestEnvironment && usesCardSetupAccessibilityTestHost {
                MobileCardSetupAccessibilityTestHost(model: model)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.accessibility5)
                    .environment(\.neoAnkiAccessibilityReduceMotionOverride, true)
            } else if usesAccessibilityUITestEnvironment {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL, packCloudTransport: packCloudTransport)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.accessibility5)
                    .environment(\.neoAnkiAccessibilityReduceMotionOverride, true)
            } else if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset")
                        && ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingLargeText") {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL, packCloudTransport: packCloudTransport)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.xxxLarge)
            } else {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL, packCloudTransport: packCloudTransport)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    guard model.loadState == .ready else { return }
                    await model.refresh()
                    if model.syncEnabled { await model.synchronize() }
                }
            } else if phase == .background {
                IOSBackgroundRefresh.shared.schedule()
            }
        }
        .onChange(of: model.syncEnabled, initial: true) { _, enabled in
            if enabled, !ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset") {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
}

@MainActor
final class IOSCloudSyncAppDelegate: NSObject, UIApplicationDelegate {
    // Available before a scene appears, including a cold background push launch.
    static weak var model: LibraryFeatureModel?
    private static let logger = Logger(subsystem: "com.neoanki2.ios", category: "CloudSyncPush")

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.logger.notice("Registered for remote change notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.logger.error("Remote notification registration failed: \((error as NSError).code, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKSyncEngineTransport.isLibraryNotification(userInfo),
              let model = Self.model else { completionHandler(.noData); return }
        Self.logger.notice("Received library change notification")
        Task {
            if model.loadState != .ready { await model.bootstrap() }
            guard model.syncEnabled else { completionHandler(.noData); return }
            await model.synchronize()
            switch model.syncStatus {
            case .current: completionHandler(.newData)
            case .syncing: completionHandler(.noData)
            default: completionHandler(.failed)
            }
        }
    }
}
