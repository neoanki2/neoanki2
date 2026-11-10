import Foundation
import NeoAnkiCore

/// Saves a portable deck using only the selected file's sandbox extension.
/// Core's atomic exporter needs a writable directory for its SQLite staging
/// file; a Save panel grants the selected file, not arbitrary siblings.
enum PortableDeckExportFile {
    @MainActor
    static func write(
        to destination: URL,
        export: @MainActor (URL) async throws -> Void
    ) async throws {
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == PortableDeck.fileExtension else {
            throw PortableDeckError.ioFailure("Export destination must be a .neodeck file URL.")
        }
        let manager = FileManager.default
        // Foundation supplies writable temporary storage on the destination's
        // volume, allowing a final atomic replacement without a parent grant.
        let directory = try manager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        var preservesRecoveryDirectory = false
        defer {
            if !preservesRecoveryDirectory { try? manager.removeItem(at: directory) }
        }
        let staged = directory.appendingPathComponent(destination.lastPathComponent)
        try await export(staged)
        try Task.checkCancellation()
        do {
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: destination)
            }
        } catch {
            // Foundation may report an original item's recovery location on
            // replacement failure. Never delete that original during cleanup.
            if let recovery = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL {
                let prefix = directory.standardizedFileURL.path + "/"
                preservesRecoveryDirectory = recovery.standardizedFileURL.path.hasPrefix(prefix)
            }
            throw error
        }
    }
}
