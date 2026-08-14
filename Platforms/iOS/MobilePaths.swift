import Foundation

struct MobilePaths: Sendable {
    let applicationSupport: URL
    let databaseURL: URL
    let syncMetadataDirectory: URL
    let backupURL: URL
    let vocabularyPacksURL: URL

    init(fileManager: FileManager = .default) {
        let support = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("neoanki2", isDirectory: true)
        try! fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        applicationSupport = support
        databaseURL = support.appendingPathComponent("neoanki2.sqlite")
        syncMetadataDirectory = support.appendingPathComponent("sync", isDirectory: true)
        backupURL = support.appendingPathComponent("pre-cloud-merge.sqlite")
        vocabularyPacksURL = support.appendingPathComponent("Vocabulary Packs", isDirectory: true)
    }
}
