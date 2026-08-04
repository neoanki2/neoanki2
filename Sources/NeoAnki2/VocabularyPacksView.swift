import SwiftUI

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
                } else if model.installedPacks.isEmpty {
                    ContentUnavailableView {
                        Label("No Vocabulary Packs", systemImage: "character.book.closed")
                    } description: {
                        Text("Import a .neovocab package once, then use it entirely offline.")
                    } actions: {
                        Button("Import Pack…", action: onImport)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isImporting)
                            .accessibilityIdentifier("importVocabularyPackEmptyState")
                    }
                } else {
                    List(model.installedPacks) { pack in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pack.title)
                                .font(.headline)
                            Text(pack.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(pack.title), \(pack.summary)")
                        .accessibilityIdentifier("vocabularyPack-\(pack.id)")
                    }
                }
            }
            .navigationTitle("Vocabulary Packs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("vocabularyPacksDone")
                }
                if !model.installedPacks.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import Pack…", systemImage: "plus", action: onImport)
                            .disabled(model.isImporting)
                            .accessibilityIdentifier("importVocabularyPack")
                    }
                }
            }
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
