import NeoAnkiApplication
import NeoAnkiFeatures
import NeoAnkiMobile
import SwiftUI
import UIKit

@main
struct NeoAnkiIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: LibraryFeatureModel

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
        if usesSyncFixture { UserDefaults.standard.set(true, forKey: "cloud-sync-enabled-v1") }
        let syncService: any SyncService = usesSyncFixture
            ? MobileSyncRecoveryUITestService(repository: repository)
            : MobileSyncCoordinator(repository: repository, paths: paths)
        let model = LibraryFeatureModel(
            library: repository,
            syncService: syncService,
            notifier: IOSNotificationScheduler(),
            widgetPublisher: AppGroupWidgetPublisher(),
            settingsStore: IOSMobileSettingsStore()
        )
        _model = State(initialValue: model)
        IOSBackgroundRefresh.shared.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            if usesAccessibilityUITestEnvironment && usesCardSetupAccessibilityTestHost {
                MobileCardSetupAccessibilityTestHost(model: model)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.accessibility5)
                    .environment(\.neoAnkiAccessibilityReduceMotionOverride, true)
            } else if usesAccessibilityUITestEnvironment {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.accessibility5)
                    .environment(\.neoAnkiAccessibilityReduceMotionOverride, true)
            } else if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset")
                        && ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingLargeText") {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL)
                    .preferredColorScheme(.dark)
                    .dynamicTypeSize(.xxxLarge)
            } else {
                NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL)
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
    }
}
