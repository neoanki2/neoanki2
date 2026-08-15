import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import NeoAnkiFeatures
import Testing

@Test func mobileFeatureUnlocksDeckTypeInPlaceAndReportsRiskyEdits() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-feature-item-types-\(UUID().uuidString)", isDirectory: true)
    let bundle = directory.appendingPathComponent("Deck.neoanki", isDirectory: true)
    let itemsDirectory = bundle.appendingPathComponent("items", isDirectory: true)
    try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manifest = """
    {"kind":"neoanki","version":3,"root":"root","parts":["items/items.jsonl"]}
    {"kind":"type","id":"Study","name":"Deck Study","fields":[{"id":"front","name":"Front","type":"text","required":true},{"id":"back","name":"Back","type":"text","required":true}],"templates":[{"name":"Card","prompt":[{"field":"front"}],"answer":[{"field":"back"}],"interaction":"reveal","skill":{"input":"text","output":"text","operation":"recall"}}]}
    {"kind":"deck","id":"root","name":"Deck","itemTypes":["Study"],"defaultType":"Study"}
    """
    let items = """
    {"kind":"item","deck":"root","type":"Study","fields":{"front":{"text":"Question"},"back":{"text":"Answer"}}}
    """
    try manifest.write(to: bundle.appendingPathComponent("deck.jsonl"), atomically: true, encoding: .utf8)
    try items.write(to: itemsDirectory.appendingPathComponent("items.jsonl"), atomically: true, encoding: .utf8)

    let store = try ItemStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    try await store.bootstrap()
    _ = try await AuthoredDeck.importDeck(from: bundle, into: store)
    let model = await LibraryFeatureModel(library: SQLiteLibraryRepository(store: store))
    await model.bootstrap(startSync: false)
    let included = try #require(await model.includedItemTypeGroups.first?.itemTypes.first)

    #expect(await model.includedItemTypeOwner(id: included.id) != nil)
    #expect(try await model.itemTypeEditingImpact(id: included.id) == .init(
        itemCount: 1,
        deckCount: 1,
        unassignedItemCount: 0
    ))
    var riskyEdit = included
    riskyEdit.fields.removeLast()
    let impact = try await model.itemTypeSchemaChangeImpact(from: included, to: riskyEdit)
    #expect(impact.requiresConfirmation)
    #expect(impact.affectedItemCount == 1)
    #expect(impact.removedPopulatedFields == ["Back"])

    try await model.unlockItemType(id: included.id)
    #expect(await model.includedItemTypeOwner(id: included.id) == nil)
    #expect(await model.itemTypes.contains { $0.id == included.id })
}
