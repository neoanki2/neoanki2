import AppKit
import NeoAnkiCore
import Observation
import UniformTypeIdentifiers

/// Finder can deliver deck URLs before the library window has finished starting.
@MainActor
@Observable
final class AuthoredDeckOpenRequests {
    private var pending: [URL] = []
    private var active: URL?

    var next: URL? { active == nil ? pending.first : nil }

    func enqueue(_ urls: [URL]) {
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == AuthoredDeck.fileExtension {
            let path = url.standardizedFileURL
            guard active?.standardizedFileURL != path,
                  !pending.contains(where: { $0.standardizedFileURL == path }) else { continue }
            pending.append(url)
        }
    }

    func claimNext() -> URL? {
        guard let next else { return nil }
        active = pending.removeFirst()
        return next
    }

    func finish(_ source: URL) {
        if active == source { active = nil }
    }

    func release(_ source: URL) {
        guard active == source else { return }
        pending.insert(source, at: 0)
        active = nil
    }
}

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
