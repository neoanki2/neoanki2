import Foundation
import Testing
@testable import NeoAnkiCore

@Test func mediaStoreIngestsAndDeduplicatesByHash() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-media-\(UUID().uuidString)", isDirectory: true)
    let store = try MediaStore(rootDirectory: root)

    let pngData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D,
    ] + Array(repeating: UInt8(0), count: 8))

    let fileURL = root.appendingPathComponent("sample.png")
    try pngData.write(to: fileURL)

    let first = try await store.ingest(url: fileURL, kind: .image, altText: "Map")
    let second = try await store.ingest(data: pngData, kind: .image, fileExtension: "png")

    #expect(first.assetHash == second.assetHash)
    #expect(first.altText == "Map")

    let resolved = try await store.resolve(first)
    #expect(FileManager.default.fileExists(atPath: resolved.path))
}

@Test func mediaValidationRejectsOversizedFile() {
    var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    data.append(contentsOf: Array(repeating: 0, count: MediaValidation.maxBytes(for: .image)))
    #expect(throws: MediaError.self) {
        try MediaValidation.validate(data: data, kind: .image, fileExtension: "png")
    }
}

@Test func clozeValidationRejectsOverlappingBlanks() {
    #expect(throws: ClozeValidationError.overlappingBlanks) {
        try ClozeValidation.validate(
            text: "Hello world",
            blanks: [
                ClozeSpan(group: 1, start: 0, length: 5),
                ClozeSpan(group: 2, start: 4, length: 3),
            ]
        )
    }
}

@Test func clozeDisplayTextHidesBlanksUntilRevealed() {
    let text = "The capital of France is Paris."
    let blanks = [ClozeSpan(group: 1, start: 25, length: 5, hint: "city")]
    let hidden = ClozeValidation.displayText(from: text, blanks: blanks, revealed: false)
    let shown = ClozeValidation.displayText(from: text, blanks: blanks, revealed: true)

    #expect(hidden.contains("[city]"))
    #expect(!hidden.contains("Paris"))
    #expect(shown.contains("Paris"))
}

@Test func clozeDisplayTextRevealsOtherGroupsButNeverLeaksCurrentAnswer() {
    let text = "Mercury Venus Earth"
    let blanks = [
        ClozeSpan(group: 1, start: 0, length: 7),
        ClozeSpan(group: 2, start: 8, length: 5),
        ClozeSpan(group: 1, start: 14, length: 5),
    ]

    let groupOnePrompt = ClozeValidation.displayText(
        from: text,
        blanks: blanks,
        revealed: false,
        group: 1
    )
    let groupTwoPrompt = ClozeValidation.displayText(
        from: text,
        blanks: blanks,
        revealed: false,
        group: 2
    )

    #expect(!groupOnePrompt.contains("Mercury"))
    #expect(!groupOnePrompt.contains("Earth"))
    #expect(groupOnePrompt.contains("Venus"))
    #expect(groupTwoPrompt.contains("Mercury"))
    #expect(!groupTwoPrompt.contains("Venus"))
    #expect(groupTwoPrompt.contains("Earth"))
}

@Test func builtInClozeTemplateDefaultsToAnswerHiding() throws {
    try ItemTypeValidation.validate(BuiltInItemTypes.cloze)
    let promptSlot = try #require(BuiltInItemTypes.cloze.templates.first?.prompt.slots.first)
    #expect(promptSlot.source == .field(BuiltInItemTypes.clozeTextFieldID))
    #expect(promptSlot.presentation.reveal == .hiddenUntilAnswer)
    #expect(BuiltInItemTypes.cloze.templates.first?.interaction == .cloze)
}

@Test func clozeGroupsPersistAndHydrateAsSeparateCards() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-cloze-cards-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ItemStore(databaseURL: root.appendingPathComponent("test.sqlite"))
    try await store.bootstrap()
    let item = Item(itemTypeID: BuiltInItemTypes.clozeID, fields: [
        FieldValue(
            fieldID: BuiltInItemTypes.clozeTextFieldID,
            value: .cloze(
                "red green blue",
                blanks: [
                    ClozeSpan(group: 4, start: 0, length: 3),
                    ClozeSpan(group: 9, start: 4, length: 5),
                    ClozeSpan(group: 4, start: 10, length: 4),
                ]
            )
        ),
        FieldValue(fieldID: BuiltInItemTypes.clozeContextFieldID, value: .empty),
    ])

    let saved = try await store.createItem(item)
    let due = try await store.fetchDueCards()

    #expect(saved.cardCount == 2)
    #expect(due.map(\.card.clozeGroup).sorted { ($0 ?? 0) < ($1 ?? 0) } == [4, 9])
    #expect(due.allSatisfy { $0.template.id == BuiltInItemTypes.clozeTemplateID })
}

@Test func fieldDefMapsMediaAndClozeContentValues() {
    let audioField = FieldDef(name: "Clip", type: .audio)
    let ref = MediaRef(kind: .audio, assetHash: "abc", fileExtension: "m4a")
    #expect(audioField.contentValue(from: ref) == .media(ref))

    let clozeField = FieldDef(name: "Sentence", type: .cloze)
    let blanks = [ClozeSpan(group: 1, start: 0, length: 4)]
    let value = clozeField.contentValue(fromClozeText: "Hello world", blanks: blanks)
    #expect(value == .cloze("Hello world", blanks: blanks))
}

@Test func importLimitsRejectOversizedPayload() {
    let huge = Data(repeating: 0x20, count: ImportLimits.maxPayloadBytes + 1)
    #expect(throws: ImportError.self) {
        try ImportLimits.validatePayloadSize(huge)
    }
}
