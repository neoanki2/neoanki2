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

    var body: some Scene {
        WindowGroup {
            Group {
                if let itemsModel, let decksModel, let schedulingModel {
                    ContentView(
                        itemsModel: itemsModel,
                        decksModel: decksModel,
                        schedulingModel: schedulingModel,
                        deckBuilderRegistry: .production
                    )
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
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            LibraryCommands()
            StudyCommands()
            SchedulingCommands(model: schedulingModel)
        }
    }

    @MainActor
    private func bootstrap() async {
        if AppDatabase.isTesting,
           ProcessInfo.processInfo.environment["NEOANKI_TEST_BOOTSTRAP_FAILURE"] == "1" {
            bootstrapError = "NeoAnki2 couldn’t open the test library."
            return
        }
        do {
            let store = try ItemStore(databaseURL: AppDatabase.defaultURL)
            try await store.bootstrap()
            try await UITestScenarioSeeder.seedIfRequested(store: store)
            let mediaStore = await store.media
            itemsModel = ItemsModel(store: store, mediaStore: mediaStore)
            decksModel = DecksModel(store: store)
            schedulingModel = SchedulingModel(store: store)
        } catch {
            bootstrapError = UserFacingError.message(from: error)
        }
    }
}

private extension DeckBuilderRegistry {
    static var production: DeckBuilderRegistry {
        DeckBuilderRegistry([
            PoemDeckBuilderFeature.makeFeature(),
        ])
    }
}
