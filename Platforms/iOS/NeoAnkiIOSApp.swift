import NeoAnkiApplication
import NeoAnkiFeatures
import NeoAnkiMobile
import SwiftUI
import UIKit

@main
struct NeoAnkiIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: LibraryFeatureModel

    init() {
        let paths = MobilePaths()
        if ProcessInfo.processInfo.arguments.contains("-NeoAnkiUITestingReset") {
            UIView.setAnimationsEnabled(false)
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
            UserDefaults.standard.removeObject(forKey: "cloud-sync-enabled-v1")
            UserDefaults.standard.removeObject(forKey: "reminder-settings-v1")
        }
        let repository = try! SQLiteLibraryRepository(databaseURL: paths.databaseURL)
        let model = LibraryFeatureModel(
            library: repository,
            syncService: MobileSyncCoordinator(repository: repository, paths: paths),
            notifier: IOSNotificationScheduler(),
            widgetPublisher: AppGroupWidgetPublisher(),
            settingsStore: IOSMobileSettingsStore()
        )
        _model = State(initialValue: model)
        IOSBackgroundRefresh.shared.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            NeoAnkiMobileScene(model: model, vocabularyRootURL: MobilePaths().vocabularyPacksURL)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh(); if model.syncEnabled { await model.synchronize() } }
            } else if phase == .background {
                IOSBackgroundRefresh.shared.schedule()
            }
        }
    }
}
