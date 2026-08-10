import NeoAnkiCore
import NeoAnkiApplication
import NeoAnkiDeckBuilderKit
import PoemDeckBuilder
import VocabularyDeckBuilder
import SwiftUI

private struct InitialLibraryPayload: Sendable {
    let library: SQLiteLibraryRepository
    let mediaStore: MediaStore?
    let snapshot: ColdLibraryHomeSnapshot?
    let vocabularyRootURL: URL
}

private let isDocumentationScreenshotCapture =
    ProcessInfo.processInfo.environment["NEOANKI_DOC_SCREENSHOTS"] == "1"

@main
struct NeoAnki2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var itemsModel: ItemsModel?
    @State private var decksModel: DecksModel?
    @State private var schedulingModel: SchedulingModel?
    @State private var library: SQLiteLibraryRepository?
    @State private var vocabularyLibraryModel: VocabularyLibraryModel?
    @State private var apiControlModel: APIControlModel?
    @State private var bootstrapError: String?
#if DEBUG
    @State private var testConfiguration: UITestRuntimeConfiguration?
    @State private var testGeneration = 0
#endif
    @State private var isBootstrapping = false
#if DEBUG
    @State private var testControlMonitor = UITestControlMonitor()
#endif
    private let initialLibraryTask: Task<InitialLibraryPayload, Error>?

    init() {
        AppStartupTrace.mark("app_init")
        if AppDatabase.isTesting {
            AppPreferences.resetForTesting()
        }
        let shouldFail = AppDatabase.isTesting
            && ProcessInfo.processInfo.environment["NEOANKI_TEST_BOOTSTRAP_FAILURE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-NeoAnkiBootstrapFailure")
        if shouldFail {
            initialLibraryTask = nil
        } else {
            let databaseURL = AppDatabase.defaultURL
            initialLibraryTask = Task.detached(priority: .userInitiated) {
                AppStartupTrace.mark("bootstrap_begin")
                try FileManager.default.createDirectory(
                    at: databaseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let library = try SQLiteLibraryRepository(databaseURL: databaseURL)
                AppStartupTrace.mark("store_opened")
                try await library.bootstrap()
                AppStartupTrace.mark("store_bootstrapped")
                try await UITestScenarioSeeder.seedIfRequested(store: library)
                AppStartupTrace.mark("scenario_ready")
                let snapshot = try? await library.coldHomeSnapshot(
                    scope: .allDecks,
                    asOf: .now
                )
                AppStartupTrace.mark("snapshot_ready")
                return InitialLibraryPayload(
                    library: library,
                    mediaStore: await library.mediaStore(),
                    snapshot: snapshot,
                    vocabularyRootURL: databaseURL.deletingLastPathComponent()
                        .appendingPathComponent("Vocabulary Packs", isDirectory: true)
                )
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let itemsModel, let decksModel, let schedulingModel, let vocabularyLibraryModel,
                   let library {
#if DEBUG
                    ContentView(
                        itemsModel: itemsModel,
                        decksModel: decksModel,
                        schedulingModel: schedulingModel,
                        vocabularyLibraryModel: vocabularyLibraryModel,
                        library: library,
                        deckBuilderRegistry: .production,
                        testingEnvironment: activeTestingEnvironment,
                        testingInitialRoute: testConfiguration?.initialRoute
                            ?? initialTestingRoute
                    )
                    .id(testGeneration)
#else
                    ContentView(
                        itemsModel: itemsModel,
                        decksModel: decksModel,
                        schedulingModel: schedulingModel,
                        vocabularyLibraryModel: vocabularyLibraryModel,
                        library: library,
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
            .preferredColorScheme(isDocumentationScreenshotCapture ? .dark : nil)
            .alert(
                "Approve Local API Client?",
                isPresented: Binding(
                    get: { apiControlModel?.pendingPairing != nil },
                    set: { visible in
                        if !visible { apiControlModel?.resolvePairing(approved: false) }
                    }
                ),
                presenting: apiControlModel?.pendingPairing
            ) { _ in
                Button("Deny", role: .cancel) {
                    apiControlModel?.resolvePairing(approved: false)
                }
                Button("Approve") {
                    apiControlModel?.resolvePairing(approved: true)
                }
            } message: { prompt in
                let origin = prompt.request.origin.map { "\nOrigin: \($0)" } ?? ""
                let scopes = prompt.request.requestedScopes.map(\.rawValue).sorted()
                    .joined(separator: ", ")
                Text("\(prompt.request.displayName) requests access.\(origin)\nScopes: \(scopes)")
            }
        }
        .defaultSize(
            width: isDocumentationScreenshotCapture ? 1_024 : 960,
            height: isDocumentationScreenshotCapture ? 680 : 640
        )
        .commands {
            LibraryCommands()
            StudyCommands()
            SchedulingCommands(model: schedulingModel)
        }

        Settings {
            if let apiControlModel {
                APISettingsView(model: apiControlModel)
            } else {
                ProgressView("Opening library…")
                    .frame(width: 420, height: 240)
            }
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
            let payload: InitialLibraryPayload
#if DEBUG
            if let testConfiguration {
                AppStartupTrace.mark("bootstrap_begin")
                let databaseURL = URL(
                    fileURLWithPath: testConfiguration.databaseDirectory,
                    isDirectory: true
                ).appendingPathComponent("test.sqlite")
                payload = try await prepareLibrary(
                    at: databaseURL,
                    scenario: testConfiguration.scenario,
                    environment: testConfiguration.environment
                )
            } else if let initialLibraryTask {
                payload = try await initialLibraryTask.value
            } else {
                AppStartupTrace.mark("bootstrap_begin")
                payload = try await prepareLibrary(at: AppDatabase.defaultURL)
            }
#else
            if let initialLibraryTask {
                payload = try await initialLibraryTask.value
            } else {
                AppStartupTrace.mark("bootstrap_begin")
                payload = try await prepareLibrary(at: AppDatabase.defaultURL)
            }
#endif
            let newItemsModel = ItemsModel(
                library: payload.library,
                mediaStore: payload.mediaStore
            )
            let newDecksModel = DecksModel(library: payload.library)
            if let snapshot = payload.snapshot {
                newDecksModel.applyColdHomeSnapshot(snapshot)
                newItemsModel.setCachedScope(.allDecks)
                newItemsModel.addItemDeckID = newDecksModel.defaultDeckIDForNewItem
                newItemsModel.applyColdHomeSnapshot(snapshot, scope: .allDecks)
            }
            itemsModel = newItemsModel
            decksModel = newDecksModel
            library = payload.library
            schedulingModel = SchedulingModel(library: payload.library)
            vocabularyLibraryModel = VocabularyLibraryModel(rootURL: payload.vocabularyRootURL)
            let apiModel = APIControlModel(
                library: payload.library,
                vocabularyRootURL: payload.vocabularyRootURL
            )
            apiControlModel = apiModel
            await apiModel.restore()
            AppStartupTrace.mark("models_ready")
        } catch {
            bootstrapError = UserFacingError.message(from: error)
        }
    }

    private func prepareLibrary(
        at databaseURL: URL,
        scenario: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> InitialLibraryPayload {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let library = try SQLiteLibraryRepository(databaseURL: databaseURL)
        AppStartupTrace.mark("store_opened")
        try await library.bootstrap()
        AppStartupTrace.mark("store_bootstrapped")
        if scenario == nil {
            try await UITestScenarioSeeder.seedIfRequested(store: library)
        } else {
            try await UITestScenarioSeeder.seed(
                scenario: scenario,
                environment: environment,
                store: library
            )
        }
        AppStartupTrace.mark("scenario_ready")
        let snapshot = try? await library.coldHomeSnapshot(
            scope: .allDecks,
            asOf: .now
        )
        AppStartupTrace.mark("snapshot_ready")
        return InitialLibraryPayload(
            library: library,
            mediaStore: await library.mediaStore(),
            snapshot: snapshot,
            vocabularyRootURL: databaseURL.deletingLastPathComponent()
                .appendingPathComponent("Vocabulary Packs", isDirectory: true)
        )
    }

    private var activeTestingEnvironment: [String: String] {
#if DEBUG
        testConfiguration?.environment ?? ProcessInfo.processInfo.environment
#else
        ProcessInfo.processInfo.environment
#endif
    }

#if DEBUG
    private var initialTestingRoute: UITestRoute {
        ProcessInfo.processInfo.environment["NEOANKI_TEST_INITIAL_ROUTE"]
            .flatMap(UITestRoute.init(rawValue:)) ?? .library
    }
#endif

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

        if command.action == .exportPortable {
            guard let library,
                  let deckID = decksModel?.selectedDeckID,
                  let path = command.path,
                  !path.isEmpty else {
                return UITestAcknowledgement(
                    sessionID: command.sessionID,
                    sequence: command.sequence,
                    state: .failed,
                    scenario: command.scenario,
                    route: command.initialRoute,
                    message: "Portable export requires an open library, selected deck, and destination"
                )
            }
            let transfer = PortableDeckTransferModel(library: library)
            let succeeded = await transfer.exportDeck(
                id: deckID,
                to: URL(fileURLWithPath: path)
            )
            return UITestAcknowledgement(
                sessionID: command.sessionID,
                sequence: command.sequence,
                state: succeeded ? .ready : .failed,
                scenario: command.scenario,
                route: command.initialRoute,
                message: succeeded ? nil : transfer.notice?.message
            )
        }

        itemsModel = nil
        decksModel = nil
        schedulingModel = nil
        vocabularyLibraryModel = nil
        bootstrapError = nil
        var environment = command.environment
        switch command.action {
        case .reset:
            break
        case .openImport:
            environment["NEOANKI_TEST_IMPORT_PATH"] = command.path
        case .openPortableImport:
            environment["NEOANKI_TEST_PORTABLE_IMPORT_PATH"] = command.path
        case .exportPortable:
            break
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
