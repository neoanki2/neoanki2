import Foundation
import NeoAnkiCore
import Testing

@testable import NeoAnki2

@MainActor
private func makeImportModel() async throws -> (ImportModel, ItemsModel, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-import-model-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let itemsModel = ItemsModel(store: store, mediaStore: await store.media)
    await itemsModel.load()
    return (ImportModel(itemsModel: itemsModel), itemsModel, directory)
}

@Test @MainActor func importModelImportsJSONAndRefreshesLibrary() async throws {
    let (model, itemsModel, directory) = try await makeImportModel()
    let fileURL = directory.appendingPathComponent("items.json")
    try """
    {
      "itemType": "Basic",
      "rows": [
        { "Front": "Question", "Back": "Answer" }
      ]
    }
    """.write(to: fileURL, atomically: true, encoding: .utf8)

    #expect(model.selectFile(fileURL))
    let imported = await model.importSelected(scope: .allDecks)

    #expect(imported)
    #expect(model.importedCount == 1)
    #expect(model.errorMessage == nil)
    #expect(itemsModel.items.map(\.title) == ["Question"])
    #expect(itemsModel.dueCount == 1)
}

@Test @MainActor func importModelRequiresItemTypeAndImportsCSV() async throws {
    let (model, itemsModel, directory) = try await makeImportModel()
    let fileURL = directory.appendingPathComponent("items.csv")
    try "Front,Back\nAlpha,Beta\n".write(to: fileURL, atomically: true, encoding: .utf8)

    #expect(model.selectFile(fileURL))
    #expect(model.needsItemTypeSelection)
    #expect(model.selectedItemTypeID == BuiltInItemTypes.basicID)

    let imported = await model.importSelected(scope: .allDecks)

    #expect(imported)
    #expect(itemsModel.items.first?.title == "Alpha")
    #expect(itemsModel.dueCount == 1)
}

@Test @MainActor func importModelMakesDuplicateBehaviorExplicitInState() async throws {
    let (model, itemsModel, directory) = try await makeImportModel()
    let fileURL = directory.appendingPathComponent("duplicates.json")
    try """
    {
      "itemType": "Basic",
      "rows": [
        { "Front": "Same", "Back": "Row" }
      ]
    }
    """.write(to: fileURL, atomically: true, encoding: .utf8)

    #expect(model.selectFile(fileURL))
    #expect(await model.importSelected(scope: .allDecks))
    #expect(await model.importSelected(scope: .allDecks))

    #expect(model.importedCount == 1)
    #expect(itemsModel.items.count == 2)
    #expect(itemsModel.dueCount == 2)
}

@Test @MainActor func importModelPropagatesBaseDirectoryForMediaPaths() async throws {
    let (model, itemsModel, directory) = try await makeImportModel()
    let image = FieldDef(name: "Image", type: .image, isRequired: true)
    let caption = FieldDef(name: "Caption", type: .text, isRequired: true)
    let template = Template(
        name: "Recognize",
        prompt: Side(slots: [Slot(source: .field(image.id))]),
        answer: Side(slots: [Slot(source: .field(caption.id))]),
        interaction: .reveal,
        skill: Skill(input: .image, output: .text, operation: .recognize)
    )
    let itemType = ItemType(
        name: "Image Notes",
        fields: [image, caption],
        templates: [template]
    )
    _ = try await itemsModel.store.createItemType(itemType)
    await itemsModel.load()

    let pngData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D,
    ] + Array(repeating: UInt8(0), count: 8))
    try pngData.write(to: directory.appendingPathComponent("picture.png"))
    let fileURL = directory.appendingPathComponent("media.json")
    try """
    {
      "itemType": "Image Notes",
      "rows": [
        {
          "Image": { "path": "picture.png" },
          "Caption": "Imported image"
        }
      ]
    }
    """.write(to: fileURL, atomically: true, encoding: .utf8)

    #expect(model.selectFile(fileURL))
    #expect(await model.importSelected(scope: .allDecks))

    let summary = try #require(itemsModel.items.first(where: { $0.itemTypeID == itemType.id }))
    let imported = try #require(try await itemsModel.store.fetchItem(id: summary.id)?.item)
    guard case let .media(ref)? = imported.value(for: image.id) else {
        Issue.record("Expected imported media value.")
        return
    }
    let mediaStore = try #require(itemsModel.mediaStore)
    let resolved = try await mediaStore.resolve(ref)
    #expect(FileManager.default.fileExists(atPath: resolved.path))
}

@Test @MainActor func importModelRejectsUnsupportedFileExtension() async throws {
    let (model, _, directory) = try await makeImportModel()
    let fileURL = directory.appendingPathComponent("items.txt")

    #expect(model.selectFile(fileURL) == false)
    #expect(model.errorMessage == "Choose a JSON or CSV file.")
    #expect(model.canImport == false)
}
