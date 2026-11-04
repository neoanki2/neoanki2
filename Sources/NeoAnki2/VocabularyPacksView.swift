import SwiftUI
import NeoAnkiSharedUI

struct VocabularyPacksView: View {
    @Bindable var model: VocabularyLibraryModel
    let onImport: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Loading installed packs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.installedPacks.isEmpty && model.sync.catalog.isEmpty {
                    if model.sync.isRefreshing { ProgressView("Refreshing dictionary catalog…") }
                    ContentUnavailableView {
                        Label("No Vocabulary Packs", systemImage: "character.book.closed")
                    } description: {
                        Text(model.sync.isEnabled ? "Import a .neovocab package. Packs from your other devices appear here after their upload finishes." : "Import a .neovocab package, or enable iCloud sync in Settings to download packs from your other devices.")
                        if let error = model.sync.catalogError { Text(error).foregroundStyle(.red) }
                    } actions: {
                        if model.sync.isEnabled {
                            Button(model.sync.catalogError == nil ? "Refresh from iCloud" : "Retry iCloud Sync") { Task { await model.sync.refresh() } }
                                .disabled(model.sync.isRefreshing)
                        }
                        Button("Import Pack…", action: onImport)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isImporting)
                            .accessibilityIdentifier("importVocabularyPackEmptyState")
                    }
                } else {
                    VocabularyPackCloudList(model: model.sync) { await model.load() }
                }
            }
            .navigationTitle("Vocabulary Packs")
            .toolbar {
                if model.sync.isEnabled {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.sync.refresh() } }.disabled(model.sync.isRefreshing)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("vocabularyPacksDone")
                }
                if !model.installedPacks.isEmpty || !model.sync.catalog.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import Pack…", systemImage: "plus", action: onImport)
                            .disabled(model.isImporting)
                            .accessibilityIdentifier("importVocabularyPack")
                    }
                }
            }
            .task { await model.load() }
            .overlay {
                if model.isImporting {
                    ZStack {
                        Rectangle()
                            .fill(.background.opacity(0.8))
                        ProgressView("Copying and validating vocabulary pack…")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("vocabularyPackImportProgress")
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .accessibilityIdentifier("vocabularyPacksSheet")
    }
}
