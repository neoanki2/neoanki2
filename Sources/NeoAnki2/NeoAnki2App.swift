import NeoAnkiCore
import SwiftUI

@main
struct NeoAnki2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: ItemsModel?
    @State private var bootstrapError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model)
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
            model = ItemsModel(store: store)
        } catch {
            bootstrapError = error.localizedDescription
        }
    }
}
