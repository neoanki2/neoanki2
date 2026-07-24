import Foundation
import Testing
@testable import NeoAnkiCore

private func tempDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki2-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite")
}

private func makeStore() async throws -> ItemStore {
    let store = try ItemStore(databaseURL: tempDatabaseURL())
    try await store.bootstrap()
    return store
}

@Test func bootstrapSeedsBasicItemType() async throws {
    let store = try await makeStore()

    let itemType = try await store.defaultItemType()

    #expect(itemType.id == BuiltInItemTypes.basicID)
    #expect(itemType.name == "Basic")
    #expect(itemType.fields.map(\.name) == ["Front", "Back"])
    #expect(itemType.templates.count == 1)
    #expect(itemType.templates.first?.interaction == .reveal)
}

@Test func createItemPersistsItemAndGeneratedCards() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Question")),
            FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Answer")),
        ]
    )

    let saved = try await store.createItem(item)
    let listed = try await store.listItems()

    #expect(saved.title == "Question")
    #expect(saved.subtitle == "Answer")
    #expect(saved.cardCount == 1)
    #expect(listed.count == 1)
    #expect(listed.first?.id == item.id)
    #expect(listed.first?.cardCount == 1)
}

@Test func itemsSurviveStoreReopen() async throws {
    let databaseURL = tempDatabaseURL()
    let itemID: UUID

    do {
        let store = try ItemStore(databaseURL: databaseURL)
        try await store.bootstrap()
        let itemType = try await store.defaultItemType()
        let item = Item(
            itemTypeID: itemType.id,
            fields: [
                FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Front")),
                FieldValue(fieldID: BuiltInItemTypes.backFieldID, value: .text("Back")),
            ]
        )
        itemID = item.id
        _ = try await store.createItem(item)
    }

    let reopened = try ItemStore(databaseURL: databaseURL)
    try await reopened.bootstrap()
    let listed = try await reopened.listItems()

    #expect(listed.count == 1)
    #expect(listed.first?.id == itemID)
    #expect(listed.first?.title == "Front")
    #expect(listed.first?.subtitle == "Back")
}

@Test func requiredFieldsMustBePresent() async throws {
    let store = try await makeStore()
    let itemType = try await store.defaultItemType()
    let item = Item(
        itemTypeID: itemType.id,
        fields: [
            FieldValue(fieldID: BuiltInItemTypes.frontFieldID, value: .text("Only front")),
        ]
    )

    await #expect(throws: DatabaseError.requiredFieldEmpty("Back")) {
        try await store.createItem(item)
    }
}
