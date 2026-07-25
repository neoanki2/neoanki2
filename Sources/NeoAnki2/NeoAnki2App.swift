import NeoAnkiCore
import SwiftUI

@main
struct NeoAnki2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var itemsModel: ItemsModel?
    @State private var decksModel: DecksModel?
    @State private var bootstrapError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let itemsModel, let decksModel {
                    ContentView(itemsModel: itemsModel, decksModel: decksModel)
                } else if let bootstrapError {
                    ContentUnavailableView {
                        Label("Could Not Start", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(bootstrapError)
                    }
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
        }
    }

    @MainActor
    private func bootstrap() async {
        do {
            let store = try ItemStore(databaseURL: AppDatabase.defaultURL)
            try await store.bootstrap()
            let mediaStore = await store.media
            itemsModel = ItemsModel(store: store, mediaStore: mediaStore)
            decksModel = DecksModel(store: store)
        } catch {
            bootstrapError = error.localizedDescription
        }
    }
}
