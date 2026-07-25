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
