import SwiftUI

struct LibraryCommandHandlers {
    var openAddItem: (() -> Void)?
    var openImport: (() -> Void)?
    var openPortableDeckImport: (() -> Void)?
    var openPortableDeckExport: (() -> Void)?
    var openDeckBuilder: (() -> Void)?
    var openTemplates: (() -> Void)?
    var openBrowse: (() -> Void)?
    var toggleAnswerColumn: (() -> Void)?
    var showSidebar: (() -> Void)?
    var isAnswerColumnVisible = false
    var canToggleAnswerColumn = false
    var canAddItem = false
    var canImport = false
    var canImportPortableDeck = false
    var canExportPortableDeck = false
    var canOpenDeckBuilder = false
    var canOpenTemplates = false
    var canBrowse = false
}

private struct LibraryCommandHandlersKey: FocusedValueKey {
    typealias Value = LibraryCommandHandlers
    static var defaultValue: LibraryCommandHandlers? { nil }
}

extension FocusedValues {
    var libraryCommandHandlers: LibraryCommandHandlers? {
        get { self[LibraryCommandHandlersKey.self] }
        set { self[LibraryCommandHandlersKey.self] = newValue }
    }
}

struct LibraryCommands: Commands {
    @FocusedValue(\.libraryCommandHandlers) private var handlers

    var body: some Commands {
        // Adding an item is the second most common thing anyone does here, so it
        // belongs where Mac users look first — and it is the only path VoiceOver
        // menu navigation can find. The standard New group is replaced rather
        // than extended because documents, windows, and tabs mean nothing here.
        CommandGroup(replacing: .newItem) {
            Button("New Item") {
                handlers?.openAddItem?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!(handlers?.canAddItem ?? false))
        }

        CommandGroup(after: .importExport) {
            Button("Import…") {
                handlers?.openImport?()
            }
            .disabled(!(handlers?.canImport ?? false))

            Divider()

            Button("Import Deck…") {
                handlers?.openPortableDeckImport?()
            }
            .disabled(!(handlers?.canImportPortableDeck ?? false))

            Button("Export Deck…") {
                handlers?.openPortableDeckExport?()
            }
            .disabled(!(handlers?.canExportPortableDeck ?? false))

            Divider()

            Button("Build Deck…") {
                handlers?.openDeckBuilder?()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!(handlers?.canOpenDeckBuilder ?? false))
        }

        CommandMenu("Library") {
#if DEBUG
            if AppDatabase.isTesting {
                Button("Show Sidebar") {
                    handlers?.showSidebar?()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()
            }
#endif
            Button("Browse Items") {
                handlers?.openBrowse?()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(!(handlers?.canBrowse ?? false))

            Button(
                handlers?.isAnswerColumnVisible == true
                    ? "Hide Answer Column"
                    : "Show Answer Column"
            ) {
                handlers?.toggleAnswerColumn?()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(!(handlers?.canToggleAnswerColumn ?? false))

            Divider()

            Button("Item Types…") {
                handlers?.openTemplates?()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!(handlers?.canOpenTemplates ?? false))
        }
    }
}
