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
