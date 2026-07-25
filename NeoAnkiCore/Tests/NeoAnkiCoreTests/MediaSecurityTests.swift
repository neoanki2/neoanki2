import Foundation
import Testing
@testable import NeoAnkiCore

private let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

@Test func mediaRefRejectsLegacyFileURLAndNeverEncodesURL() throws {
    let id = UUID()
    let legacy = """
    {"id":"\(id.uuidString)","kind":"image","url":"file:///etc/passwd"}
    """.data(using: .utf8)!

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(MediaRef.self, from: legacy)
    }

    let ref = MediaRef(
        id: id,
        kind: .image,
        assetHash: String(repeating: "a", count: 64),
        fileExtension: "png"
    )
    let encoded = try JSONEncoder().encode(ref)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["url"] == nil)
    #expect(try JSONDecoder().decode(MediaRef.self, from: encoded) == ref)

    let disguisedURL = MediaRef(
        kind: .image,
        assetHash: "file:///etc/passwd",
        fileExtension: "png"
    )
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(disguisedURL)
    }
}

@Test func mediaResolveRejectsTraversalAndEscapingSymlink() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-media-security-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try MediaStore(rootDirectory: root)
    let traversal = MediaRef(kind: .image, assetHash: "../../outside", fileExtension: "png")
    await #expect(throws: MediaError.sandboxViolation) {
        try await store.resolve(traversal)
    }

    let hash = String(repeating: "b", count: 64)
    let outside = root.appendingPathComponent("outside.png")
    try pngHeader.write(to: outside)
    let link = root.appendingPathComponent("media/\(hash).png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let symlinkRef = MediaRef(kind: .image, assetHash: hash, fileExtension: "png")
    await #expect(throws: MediaError.sandboxViolation) {
        try await store.resolve(symlinkRef)
    }
}

@Test func mediaStoreRejectsEscapingMediaDirectorySymlink() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-media-root-\(UUID().uuidString)", isDirectory: true)
    let root = parent.appendingPathComponent("root", isDirectory: true)
    let outside = parent.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("media"),
        withDestinationURL: outside
    )

    #expect(throws: MediaError.sandboxViolation) {
        _ = try MediaStore(rootDirectory: root)
    }
}

@Test func mediaIngestRejectsOversizedFileBeforeReadingContents() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("neoanki-media-size-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("oversized.png")
    FileManager.default.createFile(atPath: file.path, contents: pngHeader)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(MediaValidation.maxBytes(for: .image) + 1))
    try handle.close()

    let store = try MediaStore(rootDirectory: root)
    await #expect(throws: MediaError.fileTooLarge(.image, maxBytes: MediaValidation.maxBytes(for: .image))) {
        try await store.ingest(url: file, kind: .image)
    }
}

@Test func mediaValidationCrossChecksMagicTypeAndExtension() throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let gif = Data("GIF89a".utf8)
    let mp4 = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypisom".utf8))
    let m4a = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8))

    try MediaValidation.validate(data: pngHeader, kind: .image, fileExtension: "png")
    try MediaValidation.validate(data: jpeg, kind: .image, fileExtension: "jpeg")
    try MediaValidation.validate(data: gif, kind: .gif, fileExtension: "gif")
    try MediaValidation.validate(data: mp4, kind: .video, fileExtension: "mp4")
    try MediaValidation.validate(data: m4a, kind: .audio, fileExtension: "m4a")
    #expect(
        try MediaValidation.validatedExtension(
            data: jpeg,
            kind: .image,
            fileExtension: "jpeg"
        ) == "jpg"
    )

    #expect(throws: MediaError.unsupportedFormat(.video)) {
        try MediaValidation.validate(
            data: Data([0x00, 0x00, 0x00, 0x01]),
            kind: .video,
            fileExtension: "mp4"
        )
    }
    #expect(throws: MediaError.unsupportedFormat(.image)) {
        try MediaValidation.validate(data: gif, kind: .image, fileExtension: "png")
    }
    #expect(throws: MediaError.unsupportedFormat(.video)) {
        try MediaValidation.validate(data: m4a, kind: .video, fileExtension: "mp4")
    }
}

@Test func mediaValidationInfersCanonicalFormatsAndRejectsAmbiguity() throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let mp4 = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypisom".utf8))
    let ambiguousISO = Data(
        [0x00, 0x00, 0x00, 0x18]
            + Array("ftypisom".utf8)
            + [0x00, 0x00, 0x00, 0x00]
            + Array("M4A ".utf8)
    )

    #expect(
        try MediaValidation.detectedFormat(data: jpeg)
            == MediaValidation.DetectedFormat(kind: .image, fileExtension: "jpg")
    )
    #expect(
        try MediaValidation.detectedFormat(data: mp4)
            == MediaValidation.DetectedFormat(kind: .video, fileExtension: "mp4")
    )
    #expect(throws: MediaError.ambiguousFormat) {
        try MediaValidation.detectedFormat(data: ambiguousISO)
    }
}
