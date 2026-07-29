import NeoAnkiCore
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import SwiftUI

@main
struct NeoAnki2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var itemsModel: ItemsModel?
    @State private var decksModel: DecksModel?
    @State private var schedulingModel: SchedulingModel?
    @State private var bootstrapError: String?
#if DEBUG
    @State private var testConfiguration: UITestRuntimeConfiguration?
    @State private var testGeneration = 0
#endif
    @State private var isBootstrapping = false
#if DEBUG
    @State private var testControlMonitor = UITestControlMonitor()
#endif

    init() {
        if AppDatabase.isTesting {
            AppPreferences.resetForTesting()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let itemsModel, let decksModel, let schedulingModel {
#if DEBUG
                    ContentView(
                        itemsModel: itemsModel,
                        decksModel: decksModel,
                        schedulingModel: schedulingModel,
                        deckBuilderRegistry: .production,
                        testingEnvironment: activeTestingEnvironment,
                        testingInitialRoute: testConfiguration?.initialRoute ?? .library
                    )
                    .id(testGeneration)
#else
                    ContentView(
                        itemsModel: itemsModel,
                        decksModel: decksModel,
                        schedulingModel: schedulingModel,
                        deckBuilderRegistry: .production
                    )
#endif
                } else if let bootstrapError {
                    ContentUnavailableView {
                        Label("Could Not Start", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(bootstrapError)
                    }
                    .accessibilityIdentifier("bootstrapError")
                } else {
                    ProgressView("Starting…")
                        .task { await bootstrap() }
                }
            }
            .task {
                installUITestControlIfNeeded()
            }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            LibraryCommands()
            StudyCommands()
            SchedulingCommands(model: schedulingModel)
        }
    }

    @MainActor
    private func bootstrap() async {
        guard !isBootstrapping, itemsModel == nil else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        if AppDatabase.isTesting,
           activeTestingEnvironment["NEOANKI_TEST_BOOTSTRAP_FAILURE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-NeoAnkiBootstrapFailure") {
            bootstrapError = "NeoAnki2 couldn’t open the test library."
            return
        }
        do {
#if DEBUG
            let databaseURL = testConfiguration.map {
                URL(fileURLWithPath: $0.databaseDirectory, isDirectory: true)
                    .appendingPathComponent("test.sqlite")
            } ?? AppDatabase.defaultURL
#else
            let databaseURL = AppDatabase.defaultURL
#endif
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let store = try ItemStore(databaseURL: databaseURL)
            try await store.bootstrap()
#if DEBUG
            if let testConfiguration {
                try await UITestScenarioSeeder.seed(
                    scenario: testConfiguration.scenario,
                    environment: testConfiguration.environment,
                    store: store
                )
            } else {
                try await UITestScenarioSeeder.seedIfRequested(store: store)
            }
#else
            try await UITestScenarioSeeder.seedIfRequested(store: store)
#endif
            let mediaStore = await store.media
            itemsModel = ItemsModel(store: store, mediaStore: mediaStore)
            decksModel = DecksModel(store: store)
            schedulingModel = SchedulingModel(store: store)
        } catch {
            bootstrapError = UserFacingError.message(from: error)
        }
    }

    private var activeTestingEnvironment: [String: String] {
#if DEBUG
        testConfiguration?.environment ?? ProcessInfo.processInfo.environment
#else
        ProcessInfo.processInfo.environment
#endif
    }

    @MainActor
    private func installUITestControlIfNeeded() {
#if DEBUG
        testControlMonitor.start { command in
            await applyUITestCommand(command)
        }
#endif
    }

#if DEBUG
    @MainActor
    private func applyUITestCommand(_ command: UITestCommand) async -> UITestAcknowledgement {
        guard AppDatabase.isTesting else {
            return UITestAcknowledgement(
                sessionID: command.sessionID,
                sequence: command.sequence,
                state: .failed,
                scenario: command.scenario,
                route: command.initialRoute,
                message: "UI test control is disabled"
            )
        }

        itemsModel = nil
        decksModel = nil
        schedulingModel = nil
        bootstrapError = nil
        var environment = command.environment
        switch command.action {
        case .reset:
            break
        case .openImport:
            environment["NEOANKI_TEST_IMPORT_PATH"] = command.path
        case .openPortableImport:
            environment["NEOANKI_TEST_PORTABLE_IMPORT_PATH"] = command.path
        case .setPortableBusy:
            environment["NEOANKI_TEST_PORTABLE_BUSY"] = command.enabled == true ? "1" : "0"
        }

        testConfiguration = UITestRuntimeConfiguration(
            sequence: command.sequence,
            databaseDirectory: command.databaseDirectory,
            scenario: command.scenario?.rawValue,
            initialRoute: command.initialRoute,
            environment: environment
        )
        testGeneration = command.sequence
        AppPreferences.resetForTesting()
        await bootstrap()

        return UITestAcknowledgement(
            sessionID: command.sessionID,
            sequence: command.sequence,
            state: bootstrapError == nil ? .ready : .failed,
            scenario: command.scenario,
            route: command.initialRoute,
            message: bootstrapError
        )
    }
#endif
}

private extension DeckBuilderRegistry {
    static var production: DeckBuilderRegistry {
        DeckBuilderRegistry([
            PoemDeckBuilderFeature.makeFeature(),
        ])
    }
}
