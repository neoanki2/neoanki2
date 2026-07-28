import AppKit
import NeoAnkiCore
import UniformTypeIdentifiers

enum PortableDeckImportChoice: Equatable {
    case cancelled
    case invalidSelection
    case selected(URL)
}

enum PortableDeckImportSelection {
    static func isValid(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if fileExtension == AuthoredDeck.fileExtension {
            return isDirectory.boolValue
        }
        if fileExtension == PortableDeck.fileExtension {
            return !isDirectory.boolValue
        }
        return false
    }

    /// Presents the modal open panel, so this belongs to the main actor. Older
    /// toolchains inferred that; stating it keeps the app building under strict
    /// concurrency checking, where AppKit's isolation is enforced.
    @MainActor
    static func choose() -> PortableDeckImportChoice {
        let panel = NSOpenPanel()
        panel.title = "Import Deck"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.neoDeck, .neoAnkiSource]
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        guard isValid(url) else { return .invalidSelection }
        return .selected(url)
    }
}
