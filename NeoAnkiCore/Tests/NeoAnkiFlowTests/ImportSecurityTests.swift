import Foundation
import NeoAnkiCore
import NeoAnkiTestSupport
import Testing

private func mediaImportPayload(path: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "itemType": "Capitals",
        "rows": [
            [
                "Country": "France",
                "Capital": "Paris",
                "Map": ["path": path],
            ],
        ],
    ])
}

@Test func mediaImportIsConfinedToDeclaredBundle() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-import-security-\(UUID().uuidString)", isDirectory: true)
    let bundle = parent.appendingPathComponent("bundle", isDirectory: true)
    let nested = bundle.appendingPathComponent("assets", isDirectory: true)
    let sibling = parent.appendingPathComponent("bundle-evil", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let validFile = nested.appendingPathComponent("map.png")
    let outsideFile = sibling.appendingPathComponent("outside.png")
    try png.write(to: validFile)
    try png.write(to: outsideFile)
    try FileManager.default.createSymbolicLink(
        at: bundle.appendingPathComponent("escape.png"),
        withDestinationURL: outsideFile
    )

    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let fixture = ItemTypeFixtures.capitals()
        _ = try await ctx.store.createItemType(fixture.type)

        let hostilePaths = [
            "../../etc/passwd",
            "../bundle-evil/outside.png",
            outsideFile.path,
            "escape.png",
        ]
        for path in hostilePaths {
            let data = try mediaImportPayload(path: path)
            await #expect(throws: (any Error).self) {
                try await ctx.store.importItems(
                    from: data,
                    adapter: JSONImportAdapter(),
                    itemTypeID: fixture.type.id,
                    context: ImportContext(baseDirectory: bundle)
                )
            }
            #expect(try await ctx.store.listItems().isEmpty)
        }

        let withoutBase = try mediaImportPayload(path: "assets/map.png")
        await #expect(throws: ImportError.self) {
            try await ctx.store.importItems(
                from: withoutBase,
                adapter: JSONImportAdapter(),
                itemTypeID: fixture.type.id
            )
        }

        let valid = try mediaImportPayload(path: "assets/map.png")
        let imported = try await ctx.store.importItems(
            from: valid,
            adapter: JSONImportAdapter(),
            itemTypeID: fixture.type.id,
            context: ImportContext(baseDirectory: bundle)
        )
        #expect(imported == 1)
        #expect(try await ctx.store.listItems().count == 1)
    }
}

@Test func importFieldLimitCountsUTF8Bytes() throws {
    let exactlyLimit = String(repeating: "é", count: ImportLimits.maxFieldStringBytes / 2)
    try ImportLimits.validateFieldString(exactlyLimit, fieldName: "Text")

    #expect(throws: ImportError.self) {
        try ImportLimits.validateFieldString(exactlyLimit + "a", fieldName: "Text")
    }
}

@Test func decodedPayloadRejectsMoreThanTenThousandRows() throws {
    let atLimit = ImportPayload(
        itemTypeName: "Capitals",
        rows: Array(repeating: ImportRow(fieldValues: ["Country": "C"]), count: ImportLimits.maxRows)
    )
    try ImportLimits.validateDecodedPayload(atLimit)  // 10,000 is allowed

    let overLimit = ImportPayload(
        itemTypeName: "Capitals",
        rows: Array(repeating: ImportRow(fieldValues: ["Country": "C"]), count: ImportLimits.maxRows + 1)
    )
    #expect(throws: ImportError.self) {
        try ImportLimits.validateDecodedPayload(overLimit)
    }
    #expect(throws: ImportError.self) {
        try ImportLimits.validateRowCount(ImportLimits.maxRows + 1)
    }
}

@Test func decodedPayloadRejectsRowsWithTooManyFields() throws {
    var oversized: [String: String] = [:]
    for index in 0...ImportLimits.maxFieldsPerRow {
        oversized["Field\(index)"] = "value"
    }
    let payload = ImportPayload(
        itemTypeName: "Capitals",
        rows: [ImportRow(fieldValues: oversized)]
    )
    #expect(throws: ImportError.self) {
        try ImportLimits.validateDecodedPayload(payload)
    }
}

@Test func base64MediaCapRejectsOversizeEncodedBlob() throws {
    let smallValid = "QQ=="  // "A" base64-encoded
    try ImportLimits.validateBase64EncodedSize(smallValid, kind: .image, fieldName: "Map")

    let encodedCap = ((MediaValidation.maxBytes(for: .image) + 2) / 3) * 4
    let oversize = String(repeating: "A", count: encodedCap + 4)
    #expect(throws: ImportError.self) {
        try ImportLimits.validateBase64EncodedSize(oversize, kind: .image, fieldName: "Map")
    }
}

@Test func importRejectsMoreThanTenThousandRowsBeforePersisting() async throws {
    var rows: [[String: Any]] = []
    rows.reserveCapacity(ImportLimits.maxRows + 1)
    for index in 0...ImportLimits.maxRows {  // 10,001 rows
        rows.append(["Country": "Country \(index)", "Capital": "Capital \(index)"])
    }
    let data = try JSONSerialization.data(withJSONObject: ["itemType": "Capitals", "rows": rows])

    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let fixture = ItemTypeFixtures.capitals()
        _ = try await ctx.store.createItemType(fixture.type)

        await #expect(throws: ImportError.self) {
            try await ctx.store.importItems(
                from: data,
                adapter: JSONImportAdapter(),
                itemTypeID: fixture.type.id
            )
        }
        #expect(try await ctx.store.listItems().isEmpty)
    }
}

@Test func importRejectsOversizePayloadBeforePersisting() async throws {
    // A base64 media blob large enough to exceed a media cap also exceeds the
    // 5 MB payload cap, so it is rejected before any decoding or persistence.
    let oversizeBase64 = String(repeating: "A", count: ImportLimits.maxPayloadBytes + 1_000)
    let data = try JSONSerialization.data(withJSONObject: [
        "itemType": "Capitals",
        "rows": [
            [
                "Country": "France",
                "Capital": "Paris",
                "Map": ["base64": oversizeBase64, "fileExtension": "png"],
            ],
        ],
    ])
    #expect(data.count > ImportLimits.maxPayloadBytes)

    try await ScenarioRunner.run { ctx in
        try await ctx.onboard()
        let fixture = ItemTypeFixtures.capitals()
        _ = try await ctx.store.createItemType(fixture.type)

        await #expect(throws: ImportError.self) {
            try await ctx.store.importItems(
                from: data,
                adapter: JSONImportAdapter(),
                itemTypeID: fixture.type.id
            )
        }
        #expect(try await ctx.store.listItems().isEmpty)
    }
}
