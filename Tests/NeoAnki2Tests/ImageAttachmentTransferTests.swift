import Foundation
@testable import NeoAnkiSharedUI
import NeoAnkiCore
import Testing
import UniformTypeIdentifiers

@Suite @MainActor struct ImageAttachmentTransferTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    @Test func clipboardImageDataIsPrepared() async throws {
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let result = try await ImageAttachmentTransfer.prepare(provider: provider)
        #expect(result.data == png)
        #expect(result.fileExtension == "png")
    }

    @Test func fileRepresentationIsCopiedPreparedAndCleanedUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clipboard.png")
        try png.write(to: url)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        let result = try await ImageAttachmentTransfer.prepare(provider: provider, temporaryDirectory: directory)
        #expect(result.data == png)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["clipboard.png"])
    }

    @Test func alternativeImageRepresentationIsUsedWhenFirstIsInvalid() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in
            completion(Data("invalid TIFF".utf8), nil)
            return nil
        }
        let data = png
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let result = try await ImageAttachmentTransfer.prepare(provider: provider)
        #expect(result.data == png)
    }

    @Test func URLOnlyClipboardIsRejectedWithoutFetching() async throws {
        let provider = NSItemProvider(item: URL(string: "https://example.com/image.png")! as NSURL, typeIdentifier: UTType.url.identifier)
        await #expect(throws: MediaError.unsupportedFormat(.image)) {
            try await ImageAttachmentTransfer.prepare(provider: provider)
        }
    }

    @Test func corruptClipboardImageIsRejected() async throws {
        let provider = NSItemProvider(item: Data("bad".utf8) as NSData, typeIdentifier: UTType.png.identifier)
        await #expect(throws: MediaError.unsupportedFormat(.image)) {
            try await ImageAttachmentTransfer.prepare(provider: provider)
        }
    }
}
