import Foundation
import Testing
@testable import NeoAnkiCore

@Test func jsonImportAdapterParsesRowsAndTags() throws {
    let json = """
    {
      "itemType": "Basic",
      "rows": [
        { "Front": "One", "Back": "1", "tags": ["a", "b"] },
        { "Front": "Two", "Back": "2" }
      ]
    }
    """.data(using: .utf8)!

    let payload = try JSONImportAdapter().parse(json)

    #expect(payload.itemTypeName == "Basic")
    #expect(payload.rows.count == 2)
    #expect(payload.rows[0].fieldValues["Front"] == "One")
    #expect(payload.rows[0].fieldValues["Back"] == "1")
    #expect(payload.rows[0].tags == ["a", "b"])
    #expect(payload.rows[1].tags.isEmpty)
}

@Test func jsonImportAdapterRejectsEmptyRows() async {
    let json = """
    { "itemType": "Basic", "rows": [] }
    """.data(using: .utf8)!

    await #expect(throws: ImportError.emptyPayload) {
        try JSONImportAdapter().parse(json)
    }
}

@Test func jsonImportAdapterRejectsMalformedJSON() async {
    let json = "{ not valid json".data(using: .utf8)!

    await #expect(throws: ImportError.self) {
        try JSONImportAdapter().parse(json)
    }
}

@Test func csvImportAdapterParsesHeaderAndTagsColumn() throws {
    let csv = """
    Front,Back,tags
    Alpha,Beta,"tag1,tag2"
    Gamma,Delta,
    """.data(using: .utf8)!

    let payload = try CSVImportAdapter(itemTypeName: "Basic").parse(csv)

    #expect(payload.itemTypeName == "Basic")
    #expect(payload.rows.count == 2)
    #expect(payload.rows[0].fieldValues["Front"] == "Alpha")
    #expect(payload.rows[0].fieldValues["Back"] == "Beta")
    #expect(payload.rows[0].tags == ["tag1", "tag2"])
}

@Test func csvImportAdapterRejectsMissingDataRows() async {
    let csv = "Front,Back\n".data(using: .utf8)!

    await #expect(throws: ImportError.emptyPayload) {
        try CSVImportAdapter(itemTypeName: "Basic").parse(csv)
    }
}

@Test func csvImportAdapterRejectsInvalidUTF8() async {
    let data = Data([0xFF, 0xFE, 0xFD])

    await #expect(throws: ImportError.invalidFormat("Expected UTF-8 text.")) {
        try CSVImportAdapter(itemTypeName: "Basic").parse(data)
    }
}

@Test func csvImportAdapterParsesQuotedCommas() throws {
    let csv = """
    Front,Back
    "Hello, world",Answer
    """.data(using: .utf8)!

    let payload = try CSVImportAdapter(itemTypeName: "Basic").parse(csv)

    #expect(payload.rows.count == 1)
    #expect(payload.rows[0].fieldValues["Front"] == "Hello, world")
}

@Test func importErrorDescriptionsAreUserFacing() {
    #expect(ImportError.unknownField("Foo").errorDescription?.contains("Foo") == true)
    #expect(ImportError.emptyPayload.errorDescription?.isEmpty == false)
    #expect(ImportError.itemTypeNotFound("Missing").errorDescription?.contains("Missing") == true)
}
