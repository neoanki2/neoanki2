import SwiftUI

struct LibraryCommandHandlers {
    var openImport: (() -> Void)?
    var openPortableDeckImport: (() -> Void)?
    var openPortableDeckExport: (() -> Void)?
    var openTemplates: (() -> Void)?
    var canImport = false
    var canImportPortableDeck = false
    var canExportPortableDeck = false
    var canOpenTemplates = false
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
        }

        CommandMenu("Library") {
            Button("Item Types…") {
                handlers?.openTemplates?()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!(handlers?.canOpenTemplates ?? false))
        }
    }
}
