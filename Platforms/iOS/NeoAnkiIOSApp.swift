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
    private let fixtures: MobileUITestFixtures
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
        let badgePublisher: any AppIconBadgePublishing
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset"),
           ProcessInfo.processInfo.environment["NEOANKI_TEST_HOLD_EDIT_BADGE"] == "1",
           let rawNonce = ProcessInfo.processInfo.environment["NEOANKI_EDITOR_GATE_NONCE"],
           let nonce = UUID(uuidString: rawNonce) {
            badgePublisher = IOSItemEditBadgeUITestGate(library: repository, nonce: nonce)
        } else {
            badgePublisher = IOSAppIconBadgePublisher()
        }
        #else
        badgePublisher = IOSAppIconBadgePublisher()
        #endif
        let model = LibraryFeatureModel(
            library: repository,
            syncService: syncService,
            notifier: IOSNotificationScheduler(),
            widgetPublisher: AppGroupWidgetPublisher(),
            badgePublisher: badgePublisher,
            settingsStore: IOSMobileSettingsStore()
        )
        _model = State(initialValue: model)
        fixtures = MobileUITestFixtures(library: repository)
        IOSCloudSyncAppDelegate.model = model
        IOSBackgroundRefresh.shared.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset") && ProcessInfo.processInfo.environment["NEOANKI_TEST_SCENARIO"] == "image-occlusion" {
                MobileImageOcclusionTestHost(model: model).environment(\.mobileUITestFixtures, fixtures)
            } else if usesAccessibilityUITestEnvironment && usesCardSetupAccessibilityTestHost {
                MobileCardSetupAccessibilityTestHost(model: model).environment(\.mobileUITestFixtures, fixtures)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.accessibility5)
                    .environment(\.neoAnkiAccessibilityReduceMotionOverride, true)
            } else if usesAccessibilityUITestEnvironment {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL, packCloudTransport: packCloudTransport, fixtures: fixtures)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.accessibility5)
                    .environment(\.neoAnkiAccessibilityReduceMotionOverride, true)
            } else if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset")
                        && ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingLargeText") {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL, packCloudTransport: packCloudTransport, fixtures: fixtures)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.xxxLarge)
            } else {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL, packCloudTransport: packCloudTransport, fixtures: fixtures)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.dueCounts.setForeground(true)
                Task {
                    guard model.loadState == .ready else { return }
                    await model.refresh()
                    if model.syncEnabled { await model.synchronize() }
                }
            } else {
                model.dueCounts.setForeground(false)
                if phase == .background {
                    IOSBackgroundRefresh.shared.schedule()
                    if model.syncEnabled { IOSBackgroundRefresh.shared.scheduleLibraryProcessing() }
                }
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
            if model.loadState != .ready { await model.bootstrap(startSync: false) }
            guard model.loadState == .ready else { completionHandler(.failed); return }
            guard model.syncEnabled else { completionHandler(.noData); return }
            IOSBackgroundRefresh.shared.scheduleLibraryProcessing()
            await model.synchronize()
            switch model.syncStatus {
            case .current: completionHandler(.newData)
            case .syncing: completionHandler(.noData)
            default: completionHandler(.failed)
            }
        }
    }
}
