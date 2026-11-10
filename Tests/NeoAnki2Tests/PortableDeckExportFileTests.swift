import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Testing

@testable import NeoAnki2

private func exportFileTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("portable-export-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test(arguments: [false, true]) @MainActor
func portableDeckSelectedFileSavePublishesCompleteBytes(replacing: Bool) async throws {
    let root = try exportFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Chosen.neodeck")
    let original = Data("existing user document".utf8)
    let complete = Data("complete portable deck".utf8)
    if replacing { try original.write(to: destination) }
    var staging: URL?

    try await PortableDeckExportFile.write(to: destination) { file in
        staging = file.deletingLastPathComponent()
        #expect(file.deletingLastPathComponent() != root)
        #expect(file.pathExtension == PortableDeck.fileExtension)
        #expect(FileManager.default.fileExists(atPath: destination.path) == replacing)
        if replacing { #expect(try Data(contentsOf: destination) == original) }
        try complete.write(to: file)
    }

    #expect(try Data(contentsOf: destination) == complete)
    let stagedDirectory = try #require(staging)
    #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Chosen.neodeck"])
}

@Test(arguments: [false, true]) @MainActor
func portableDeckSelectedFileSavePreservesDestinationOnExportFailure(replacing: Bool) async throws {
    let root = try exportFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Chosen.neodeck")
    let original = Data("existing user document".utf8)
    if replacing { try original.write(to: destination) }
    var staging: URL?

    await #expect(throws: PortableDeckError.self) {
        try await PortableDeckExportFile.write(to: destination) { file in
            staging = file.deletingLastPathComponent()
            try Data("incomplete output".utf8).write(to: file)
            throw PortableDeckError.ioFailure("Export stopped before producing a complete deck.")
        }
    }

    #expect(FileManager.default.fileExists(atPath: destination.path) == replacing)
    if replacing { #expect(try Data(contentsOf: destination) == original) }
    let stagedDirectory = try #require(staging)
    #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
}

@Test(arguments: [false, true]) @MainActor
func portableDeckSelectedFileSavePreservesDestinationOnCommitFailure(replacing: Bool) async throws {
    let root = try exportFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("Chosen.neodeck")
    let original = Data("existing user document".utf8)
    if replacing { try original.write(to: destination) }
    var staging: URL?

    await #expect(throws: (any Error).self) {
        try await PortableDeckExportFile.write(to: destination) { file in
            staging = file.deletingLastPathComponent()
            try Data("complete output".utf8).write(to: file)
            // A missing completed artifact forces the real Foundation commit
            // to fail. The adapter must not pre-delete the selected document.
            try FileManager.default.removeItem(at: file)
        }
    }

    #expect(FileManager.default.fileExists(atPath: destination.path) == replacing)
    if replacing { #expect(try Data(contentsOf: destination) == original) }
    let stagedDirectory = try #require(staging)
    #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
}

@Test @MainActor
func portableDeckSelectedFileSaveRejectsInvalidDestinationBeforeExport() async throws {
    let root = try exportFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var exported = false
    await #expect(throws: PortableDeckError.self) {
        try await PortableDeckExportFile.write(to: root.appendingPathComponent("Wrong.txt")) { _ in
            exported = true
        }
    }
    #expect(!exported)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test @MainActor
func portableDeckSelectedFileSaveProductionModelRoundTripsActualDeck() async throws {
    let root = try exportFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("source.sqlite"))
    try await library.bootstrap()
    let deck = try await library.createDeck(Deck(name: "Sandbox export"))
    _ = try await library.createItem(Item(
        itemTypeID: BuiltInItemTypes.basicID,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Export question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Export answer")),
        ],
        deckID: deck.id
    ), asOf: .now)
    let model = PortableDeckTransferModel(library: library)
    let destination = root.appendingPathComponent("Chosen.neodeck")
    #expect(await model.exportDeck(id: deck.id, to: destination))
    #expect(model.notice?.title == "Deck Exported")
    let imported = try SQLiteLibraryRepository(databaseURL: root.appendingPathComponent("imported.sqlite"))
    try await imported.bootstrap()
    let result = try await imported.importPortableDeck(from: destination, conflictResolution: .reject)
    #expect(result.itemCount == 1)
    #expect(try await imported.listItems().first?.title == "Export question")
}
