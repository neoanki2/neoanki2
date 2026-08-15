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

@Test func jsonImportAdapterRejectsEmptyRows() {
    let json = """
    { "itemType": "Basic", "rows": [] }
    """.data(using: .utf8)!

    #expect(throws: ImportError.emptyPayload) {
        try JSONImportAdapter().parse(json)
    }
}

@Test func jsonImportAdapterRejectsMalformedJSON() {
    let json = "{ not valid json".data(using: .utf8)!

    #expect(throws: ImportError.self) {
        try JSONImportAdapter().parse(json)
    }
}

@Test func jsonImportAdapterRejectsUnsupportedFieldValueShapes() {
    for jsonText in [
        #"{"itemType":"Basic","rows":[{"Front":"Question","Back":7}]}"#,
        #"{"itemType":"Basic","rows":[{"Front":"Question","Back":"Answer","Unknown":false}]}"#,
    ] {
        let json = Data(jsonText.utf8)
        #expect(throws: ImportError.self) {
            try JSONImportAdapter().parse(json)
        }
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

@Test func csvImportAdapterRejectsMissingDataRows() {
    let csv = "Front,Back\n".data(using: .utf8)!

    #expect(throws: ImportError.emptyPayload) {
        try CSVImportAdapter(itemTypeName: "Basic").parse(csv)
    }
}

@Test func csvImportAdapterRejectsInvalidUTF8() {
    let data = Data([0xFF, 0xFE, 0xFD])

    #expect(throws: ImportError.invalidFormat("Expected UTF-8 text.")) {
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

@Test func csvImportAdapterParsesMultilineEscapedQuotesAndCRLF() throws {
    let csv = "Front,Back\r\n\"Line one\r\nLine \"\"two\"\"\",Answer\r\n"
        .data(using: .utf8)!

    let payload = try CSVImportAdapter(itemTypeName: "Basic").parse(csv)

    #expect(payload.rows.count == 1)
    #expect(payload.rows[0].fieldValues["Front"] == "Line one\nLine \"two\"")
    #expect(payload.rows[0].fieldValues["Back"] == "Answer")
}

@Test func csvImportAdapterRejectsUnclosedQuotes() {
    let csv = "Front,Back\n\"never ends,Answer".data(using: .utf8)!

    #expect(throws: ImportError.self) {
        try CSVImportAdapter(itemTypeName: "Basic").parse(csv)
    }
}

@Test func csvImportAdapterRejectsOversizedFieldDuringParsing() {
    let oversized = String(repeating: "x", count: ImportLimits.maxFieldStringBytes + 1)
    let csv = "Front,Back\n\(oversized),Answer".data(using: .utf8)!

    #expect(throws: ImportError.self) {
        try CSVImportAdapter(itemTypeName: "Basic").parse(csv)
    }
}

@Test func csvImportAdapterRejectsTooManyRowsDuringParsing() {
    let rows = Array(repeating: "Question,Answer", count: ImportLimits.maxRows + 1)
    let csv = (["Front,Back"] + rows).joined(separator: "\n").data(using: .utf8)!

    #expect(throws: ImportError.self) {
        try CSVImportAdapter(itemTypeName: "Basic").parse(csv)
    }
}

@Test func decodedPayloadRejectsTooManyFieldsBeforePersistence() {
    let values = Dictionary(
        uniqueKeysWithValues: (0...ImportLimits.maxFieldsPerRow).map { ("Field \($0)", "value") }
    )
    let payload = ImportPayload(
        itemTypeName: "Basic",
        rows: [ImportRow(fieldValues: values)]
    )

    #expect(throws: ImportError.self) {
        try ImportLimits.validateDecodedPayload(payload)
    }
}

@Test func importErrorDescriptionsAreUserFacing() {
    #expect(ImportError.unknownField("Foo").errorDescription?.contains("Foo") == true)
    #expect(ImportError.emptyPayload.errorDescription?.isEmpty == false)
    #expect(ImportError.itemTypeNotFound("Missing").errorDescription?.contains("Missing") == true)
}
